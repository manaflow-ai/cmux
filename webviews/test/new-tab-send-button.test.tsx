// The New Tab field's Return glyph (dogfood run, hq #1893): it looked like the send button, but a
// click on it did nothing; only the Return key sent the prompt. It is the Send button now, and a
// click asks the agent as Return does.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { noChat } from "../src/gallery/fixtures/acpmux";

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

beforeAll(() => {
  const { window } = new JSDOM("<!doctype html><div id=root></div>");
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

test("a click on the field's Send button asks the agent, as Return does", async () => {
  const { createRoot } = await import("react-dom/client");
  const { NewTabScreen } = await import("../src/agent-session/acpmux/newtab/NewTabScreen");
  const asked: unknown[][] = [];
  root = createRoot(host);
  await act(async () =>
    root!.render(
      <NewTabScreen
        snapshot={noChat()}
        lastAgent="claude"
        cwd="/Users/you/src/app"
        onAsk={(...args) => asked.push(args)}
        onOpen={noop}
        onSearch={noop}
        onShell={noop}
        onJump={noop}
        onOpenSession={noop}
        onShowAll={noop}
      />,
    ),
  );
  const field = host.querySelector<HTMLTextAreaElement>(".nt-field")!;
  const setValue = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(field), "value")!.set!;
  await act(async () => {
    setValue.call(field, "fix the flaky upload test");
    field.dispatchEvent(new window.Event("input", { bubbles: true }));
  });

  const send = host.querySelector<HTMLButtonElement>('button[aria-label="Send"]');
  expect(send).not.toBeNull();
  await act(async () => send!.click());
  // On the model the chip names (cx-sljrg).
  expect(asked).toEqual([["claude", "fix the flaky upload test", "/Users/you/src/app", "claude-opus-5-5"]]);
});

test("New Tab /import opens the transcript flow and never sends the slash token as a prompt", async () => {
  const { createRoot } = await import("react-dom/client");
  const { NewTabScreen } = await import("../src/agent-session/acpmux/newtab/NewTabScreen");
  const asked: unknown[][] = [];
  const imported: File[] = [];
  root = createRoot(host);
  await act(async () =>
    root!.render(
      <NewTabScreen
        snapshot={noChat()}
        lastAgent="claude"
        cwd="/Users/you/src/app"
        onAsk={(...args) => asked.push(args)}
        onImportFile={(file) => {
          imported.push(file);
        }}
        onOpen={noop}
        onSearch={noop}
        onShell={noop}
        onJump={noop}
        onOpenSession={noop}
        onShowAll={noop}
      />,
    ),
  );
  const field = host.querySelector<HTMLTextAreaElement>(".nt-field")!;
  const setValue = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(field), "value")!.set!;
  await act(async () => {
    setValue.call(field, "/import");
    field.dispatchEvent(new window.Event("input", { bubbles: true }));
  });
  const input = host.querySelector<HTMLInputElement>('input[aria-label="/import"]')!;
  let opened = false;
  input.click = () => {
    opened = true;
  };
  await act(async () => host.querySelector<HTMLButtonElement>('button[aria-label="Send"]')!.click());
  expect(opened).toBe(true);
  expect(asked).toEqual([]);
  const file = new window.File(["{}"], "transcript.json", { type: "application/json" });
  Object.defineProperty(input, "files", { configurable: true, value: [file] });
  await act(async () => input.dispatchEvent(new window.Event("change", { bubbles: true })));
  expect(imported).toEqual([file]);
});

test("classic New Tab intercepts /import before its omnibar can treat it as a path", async () => {
  const { createRoot } = await import("react-dom/client");
  const { NewTabPage } = await import("../src/agent-session/acpmux/NewTabPage");
  const submitted: unknown[][] = [];
  const imported: File[] = [];
  root = createRoot(host);
  await act(async () =>
    root!.render(
      <NewTabPage
        snapshot={noChat()}
        lastAgent="claude"
        onSubmit={(...args) => {
          submitted.push(args);
        }}
        onImportFile={(file) => {
          imported.push(file);
        }}
        onOpenSession={noop}
        onShowAll={noop}
      />,
    ),
  );
  const field = host.querySelector<HTMLInputElement>("input:not([type=file])")!;
  const setValue = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(field), "value")!.set!;
  await act(async () => {
    setValue.call(field, "/import");
    field.dispatchEvent(new window.Event("input", { bubbles: true }));
  });
  const input = host.querySelector<HTMLInputElement>('input[aria-label="/import"]')!;
  let opened = false;
  input.click = () => {
    opened = true;
  };
  await act(async () =>
    host.querySelector("form")!.dispatchEvent(new window.Event("submit", { bubbles: true, cancelable: true })),
  );
  expect(opened).toBe(true);
  expect(submitted).toEqual([]);
  const file = new window.File(["{}"], "transcript.json", { type: "application/json" });
  Object.defineProperty(input, "files", { configurable: true, value: [file] });
  await act(async () => input.dispatchEvent(new window.Event("change", { bubbles: true })));
  expect(imported).toEqual([file]);
});
