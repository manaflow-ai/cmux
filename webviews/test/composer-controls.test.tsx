// l10n-allow-file: regression prompts, shell commands and test picker labels, not shipped UI.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import type { ComposerHandle } from "../src/agent-session/acpmux/Composer";
import { noChat } from "../src/gallery/fixtures/acpmux";
import { composerControl } from "../src/agent-session/acpmux/composerControls";
import { registerPicker } from "../src/agent-session/acpmux/pickerOpeners";

const scope = globalThis as Record<string, unknown>;
const keys = [
  "window",
  "document",
  "navigator",
  "HTMLElement",
  "IS_REACT_ACT_ENVIRONMENT",
  "Node",
  "Element",
  "MutationObserver",
  "ResizeObserver",
  "getComputedStyle",
  "requestAnimationFrame",
  "cancelAnimationFrame",
  "localStorage",
  "KeyboardEvent",
  "InputEvent",
] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let dom: JSDOM;
let root: Root | undefined;
let host: HTMLElement;
let unregister: (() => void) | undefined;

beforeAll(() => {
  dom = new JSDOM("<!doctype html><div id=root></div>", { pretendToBeVisual: true, url: "https://cmux.test/" });
  const { window } = dom;
  Object.assign(scope, {
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    IS_REACT_ACT_ENVIRONMENT: true,
    Node: window.Node,
    Element: window.Element,
    MutationObserver: window.MutationObserver,
    ResizeObserver: class {
      observe() {}
      unobserve() {}
      disconnect() {}
    },
    getComputedStyle: window.getComputedStyle.bind(window),
    requestAnimationFrame: (run: (time: number) => void) => setTimeout(() => run(0), 0),
    cancelAnimationFrame: (id: number) => clearTimeout(id),
    localStorage: window.localStorage,
    KeyboardEvent: window.KeyboardEvent,
    InputEvent: window.InputEvent,
  });
  host = window.document.getElementById("root")!;
});

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
  unregister?.();
  unregister = undefined;
  host.replaceChildren();
});
afterAll(() => {
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const noop = () => {};
function Chips() {
  return null;
}

async function composer(text: string, shell: boolean, opens?: () => void) {
  const { createRoot } = await import("react-dom/client");
  const { Composer } = await import("../src/agent-session/acpmux/Composer");
  const calls: [string, string][] = [];
  let handle: ComposerHandle | null = null;
  if (opens) unregister = registerPicker("Model", opens);
  root = createRoot(host);
  await act(async () =>
    root!.render(
      <Composer
        snapshot={noChat([], { summary: { sessionId: "chat", harness: "codex", cwd: "/tmp/project" } })}
        chips={Chips}
        onSend={(prompt) => {
          calls.push(["send", prompt]);
          return true;
        }}
        onStop={noop}
        onShell={(command) => {
          calls.push(["shell", command]);
          return undefined;
        }}
        handle={(next) => {
          handle = next;
        }}
      />,
    ),
  );
  await act(async () => (shell ? handle!.wake({ shell: true, shellText: text }) : handle!.restore(text, [])));
  const field = host.querySelector(shell ? ".acpmux-shell-field" : ".ProseMirror")!;
  await act(async () => field.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: "Enter", bubbles: true })));
  return calls;
}

test("chat controls have a shared classifier, while executable paths and agent commands stay intact", () => {
  for (const text of ["/fast", "/fast on", "/account", "/effort", "/model"])
    expect(composerControl(text)).toBe("model");
  for (const text of ["/bin/echo", "/usr/bin/true", "echo /fast", "/model gpt-6"])
    expect(composerControl(text)).toBeUndefined();
});

test("/fast opens the current model menu without sending an agent prompt", async () => {
  let opened = 0;
  expect(await composer("/fast", false, () => opened++)).toEqual([]);
  expect(opened).toBe(1);
});

test("the reported ! /fast opens the model menu and never reaches the shell", async () => {
  let opened = 0;
  expect(await composer("/fast", true, () => opened++)).toEqual([]);
  expect(opened).toBe(1);
  expect(host.querySelector(".acpmux-shell-field")).toBeNull();
});

test("a control without a mounted picker leaves shell mode and keeps its draft", async () => {
  expect(await composer("/fast", true)).toEqual([]);
  expect(host.querySelector(".acpmux-shell-field")).toBeNull();
  expect(host.querySelector(".ProseMirror")!.textContent).toBe("/fast");
});

test("an explicit ! executable path still reaches the shell unchanged", async () => {
  expect(await composer("/usr/bin/true", true)).toEqual([["shell", "/usr/bin/true"]]);
});

async function newTab(text: string, opens?: () => void) {
  const { createRoot } = await import("react-dom/client");
  const { NewTabScreen } = await import("../src/agent-session/acpmux/newtab/NewTabScreen");
  const calls: [string, string][] = [];
  if (opens) unregister = registerPicker("Model", opens);
  root = createRoot(host);
  await act(async () =>
    root!.render(
      <NewTabScreen
        snapshot={noChat()}
        lastAgent="codex"
        cwd="/tmp/project"
        onAsk={(_harness, prompt) => calls.push(["ask", prompt])}
        onShell={(command) => calls.push(["shell", command])}
        onOpen={noop}
        onSearch={noop}
        onJump={noop}
        onOpenSession={noop}
        onShowAll={noop}
      />,
    ),
  );
  const input = host.querySelector<HTMLTextAreaElement>("textarea")!;
  const setter = Object.getOwnPropertyDescriptor(dom.window.HTMLTextAreaElement.prototype, "value")!.set!;
  await act(async () => {
    setter.call(input, text);
    input.dispatchEvent(new dom.window.Event("input", { bubbles: true }));
  });
  await act(async () => input.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: "Enter", bubbles: true })));
  return calls;
}

test.each(["/fast", "! /fast"])("New Tab routes %s to its picker without starting a chat or shell", async (text) => {
  let opened = 0;
  expect(await newTab(text, () => opened++)).toEqual([]);
  expect(opened).toBe(1);
});

test("New Tab keeps explicit shell commands", async () => {
  expect(await newTab("! printf hello")).toEqual([["shell", "printf hello"]]);
});
