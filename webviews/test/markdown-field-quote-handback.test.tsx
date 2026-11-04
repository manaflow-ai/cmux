// Quote in Reply while the composer's editor is still being made: the field queues the quote until
// Milkdown is up. Review (Codex): a composer that went before then (a Sandboxed receipt, a handoff
// review) took the queue with it, and since the host had handed the quote to a live composer it held
// no copy, so the quote was lost. The field now hands what it never placed back to the host, which
// puts it into the next composer, once.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act, createRef } from "react";
import type { Root } from "react-dom/client";
import type { MarkdownFieldHandle } from "../src/agent-session/acpmux/MarkdownField";
import { proseMirrorGlobals } from "../src/agent-session/acpmux/promptFieldTesting";

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
  "getSelection",
  "getComputedStyle",
  "requestAnimationFrame",
  "cancelAnimationFrame",
  "KeyboardEvent",
  "InputEvent",
  "FocusEvent",
] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let dom: JSDOM;
let root: Root | undefined;
let host: HTMLElement;

beforeAll(() => {
  dom = new JSDOM("<!doctype html><div id=root></div>", { pretendToBeVisual: true, url: "https://cmux.test/" });
  const { window } = dom;
  Object.assign(scope, {
    ResizeObserver: class {
      observe() {}
      unobserve() {}
      disconnect() {}
    },
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

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
  host.replaceChildren();
});

afterAll(() => {
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const QUOTE = "> Keep this line\n\n";
const settle = () => act(async () => new Promise((resolve) => setTimeout(resolve, 0)));

/// The host's side (App.tsx): the composer it quotes into, and the quotes it holds while none is up.
function hostState() {
  return {
    composer: { current: null as MarkdownFieldHandle | null },
    heldBack: { current: undefined as { text: string; attachments: [] }[] | undefined },
    heldQuotes: { current: undefined as string[] | undefined },
  };
}

/// Mounts a field as the composer's prompt, wired as App wires the composer, without waiting for
/// its editor. `whenReady` resolves once Milkdown is up.
async function mount(state: ReturnType<typeof hostState>) {
  const { createRoot } = await import("react-dom/client");
  const { MarkdownField } = await import("../src/agent-session/acpmux/MarkdownField");
  const { handBackQuotes, replayHeldForComposer } = await import("../src/agent-session/acpmux/composerRestore");
  const handle = createRef<MarkdownFieldHandle>();
  let ready = false;
  root ??= createRoot(host);
  act(() =>
    root!.render(
      <MarkdownField
        ref={(field) => {
          (handle as { current: MarkdownFieldHandle | null }).current = field;
          state.composer.current = field;
          if (field) replayHeldForComposer({ ...field, restore: () => {} }, state.heldBack, state.heldQuotes);
        }}
        value=""
        onChange={() => {}}
        onReady={() => (ready = true)}
        onUnplacedQuotes={(quotes) => handBackQuotes(state.composer, state.heldQuotes, quotes)}
      />,
    ),
  );
  return {
    handle,
    isReady: () => ready,
    async whenReady() {
      for (let turn = 0; turn < 200 && !ready; turn++) await settle();
      for (let turn = 0; turn < 5; turn++) await settle();
      expect(ready).toBe(true);
    },
  };
}

function quoteCount(markdown: string) {
  return markdown.split("Keep this line").length - 1;
}

test("a quote taken before the editor is up survives the composer going, and goes in once on remount", async () => {
  const { quoteIntoComposer } = await import("../src/agent-session/acpmux/composerRestore");
  const state = hostState();
  const first = await mount(state);
  expect(state.composer.current).not.toBeNull();
  expect(first.isReady()).toBe(false);

  // Quote in Reply while Milkdown is still being made: the composer is there, so the host holds nothing.
  quoteIntoComposer(state.composer, state.heldQuotes, QUOTE);
  expect(state.heldQuotes.current).toBeUndefined();

  // The composer goes before its editor is made (a Sandboxed receipt opened).
  act(() => root!.unmount());
  root = undefined;
  expect(first.isReady()).toBe(false);
  expect(state.composer.current).toBeNull();
  expect(state.heldQuotes.current).toEqual([QUOTE]);

  // Back: a new composer mounts and takes the quote, once.
  const second = await mount(state);
  expect(state.heldQuotes.current).toBeUndefined();
  await second.whenReady();
  const value = second.handle.current!.value();
  expect(quoteCount(value)).toBe(1);
  expect(value).toContain("> Keep this line");
  expect(state.heldQuotes.current).toBeUndefined();
});

test("a quote into a ready composer goes in once and leaves no held copy", async () => {
  const { quoteIntoComposer } = await import("../src/agent-session/acpmux/composerRestore");
  const state = hostState();
  const field = await mount(state);
  await field.whenReady();

  quoteIntoComposer(state.composer, state.heldQuotes, QUOTE);
  await settle();
  expect(quoteCount(field.handle.current!.value())).toBe(1);
  expect(state.heldQuotes.current).toBeUndefined();

  // Going after the editor is up hands nothing back: the quote is the draft's now.
  act(() => root!.unmount());
  root = undefined;
  expect(state.heldQuotes.current).toBeUndefined();
});

test("a quote taken before the editor is up goes in once when it is made", async () => {
  const { quoteIntoComposer } = await import("../src/agent-session/acpmux/composerRestore");
  const state = hostState();
  const field = await mount(state);
  expect(field.isReady()).toBe(false);
  quoteIntoComposer(state.composer, state.heldQuotes, QUOTE);
  await field.whenReady();
  expect(quoteCount(field.handle.current!.value())).toBe(1);
  expect(state.heldQuotes.current).toBeUndefined();
  act(() => root!.unmount());
  root = undefined;
  expect(state.heldQuotes.current).toBeUndefined();
});
