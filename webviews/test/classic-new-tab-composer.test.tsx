// The classic New Tab page (the Terminal | Browser | Agent template, NewTabPage.tsx) types into the
// same composer field as the chat and the New Tab screen: the chat composer's prompt editor
// (MarkdownField), never a plain <input> of its own. Leo, 2026-10-21: "I STILL DONT HAVE THE GOOD
// COMPOSER EVERYWHERE THE MODEL PICKER THE NEW TAB PAGE ALL THE STUFF". leo-workspace
// design/new-tab.md: one composer; a template that draws its own field breaks it.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { noChat } from "../src/gallery/fixtures/acpmux";
import { proseMirrorGlobals } from "../src/agent-session/acpmux/promptFieldTesting";
import { classicField } from "./support/classicNewTabField";
import { teardownDom } from "./support/domTeardown";

const scope = globalThis as Record<string, unknown>;
const keys = [
  "window",
  "document",
  "navigator",
  "HTMLElement",
  "Element",
  "Node",
  "Event",
  "KeyboardEvent",
  "InputEvent",
  "MouseEvent",
  "FocusEvent",
  "IS_REACT_ACT_ENVIRONMENT",
  "getComputedStyle",
  "requestAnimationFrame",
  "cancelAnimationFrame",
  "localStorage",
  "MutationObserver",
  "getSelection",
] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let window: JSDOM["window"];
let host: HTMLElement;
let root: Root | undefined;

beforeAll(() => {
  window = new JSDOM("<!doctype html><div id=root></div>", {
    pretendToBeVisual: true,
    url: "http://localhost/",
  }).window;
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
    Element: window.Element,
    Event: window.Event,
    KeyboardEvent: window.KeyboardEvent,
    InputEvent: window.InputEvent,
    MouseEvent: window.MouseEvent,
    FocusEvent: window.FocusEvent,
    IS_REACT_ACT_ENVIRONMENT: true,
    getComputedStyle: window.getComputedStyle.bind(window),
    requestAnimationFrame: (run: (time: number) => void) => setTimeout(() => run(0), 0),
    cancelAnimationFrame: (id: number) => clearTimeout(id),
    localStorage: window.localStorage,
    ...proseMirrorGlobals(window as unknown as Window & typeof globalThis),
  });
  host = window.document.getElementById("root")!;
});

afterEach(async () => {
  await act(async () => root?.unmount());
  root = undefined;
});

afterAll(async () => {
  await teardownDom(saved, { window, scope });
});

const noop = () => {};

async function render(submitted: unknown[][] = []) {
  const { createRoot } = await import("react-dom/client");
  const { NewTabPage } = await import("../src/agent-session/acpmux/NewTabPage");
  root = createRoot(host);
  await act(async () =>
    root!.render(
      <NewTabPage
        snapshot={noChat()}
        initialKind="agent"
        cwd="/Users/you/src/app"
        onSubmit={(...args) => {
          submitted.push(args);
        }}
        onOpenSession={noop}
        onShowAll={noop}
      />,
    ),
  );
  return classicField(host);
}

test("the classic New Tab page types into the chat composer's prompt editor, not a plain input", async () => {
  const field = await render();
  // No text field of its own: the only inputs are hidden file pickers.
  const plain = [...host.querySelectorAll<HTMLInputElement>("input, textarea")].filter(
    (input) => !(input instanceof window.HTMLInputElement && input.type === "file"),
  );
  expect(plain.map((input) => input.outerHTML)).toEqual([]);
  expect(field.field.classList.contains("acpmux-md-field")).toBe(true);
  expect(field.editor.isContentEditable || field.editor.getAttribute("contenteditable") === "true").toBe(true);
  // The template keeps its Terminal | Browser | Agent switch.
  expect(
    [...host.querySelectorAll(".acpmux-newtab-switch .acpmux-newtab-kind")].map((kind) => kind.textContent),
  ).toEqual(["Terminal", "Browser", "Agent"]);
});

test("Return in the classic field opens what was typed, as the agent gets it", async () => {
  const submitted: unknown[][] = [];
  const field = await render(submitted);
  await field.type("fix *this* test");
  await act(async () =>
    field.editor.dispatchEvent(new window.KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true })),
  );
  expect(submitted.map(([kind, text, cwd]) => [kind, text, cwd])).toEqual([
    ["agent", "fix *this* test", "/Users/you/src/app"],
  ]);
});

test("a typed ! switches the classic field to a terminal and leaves it empty", async () => {
  const field = await render();
  await act(async () => field.editor.focus());
  await act(async () => field.handle.insertTyped("!"));
  expect(host.querySelector(".acpmux-newtab")?.getAttribute("data-kind")).toBe("terminal");
  expect(field.value()).toBe("");
});

test("in a prompt of several lines, ↑ moves the caret up a line and ↓ on the last line steps the suggestions", async () => {
  const field = await render();
  await field.type("first line\nsecond line");
  expect(host.querySelectorAll('[role="option"]').length).toBeGreaterThan(0);
  const press = async (key: string) => {
    const event = new window.KeyboardEvent("keydown", { key, bubbles: true, cancelable: true });
    await act(async () => field.editor.dispatchEvent(event));
    return event.defaultPrevented;
  };
  // The caret is on the last line: ↑ has a line to move to, so the editor keeps it.
  expect(await press("ArrowUp")).toBe(false);
  // ↓ has none: it steps the rows.
  expect(await press("ArrowDown")).toBe(true);
});

test("a press on the classic field's padding, above or below its text, focuses the editor", async () => {
  const field = await render();
  await act(async () => field.editor.blur());
  expect(window.document.activeElement).not.toBe(field.editor);
  // The press lands on the field's own wrapper (its padding), not on the editable text.
  const press = new window.MouseEvent("mousedown", { bubbles: true, cancelable: true });
  await act(async () => field.field.dispatchEvent(press));
  expect(press.defaultPrevented).toBe(true);
  expect(field.editor.contains(window.document.activeElement)).toBe(true);
});
