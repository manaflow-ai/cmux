import { afterAll, describe, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";

// R135: one prompt editor for the agent chat and the new tab page (PromptEditor). The surface
// sees typed text before the editor inserts it (the new tab's "!" rule), submits through
// onSubmit, reads plain text, and passes its own keymap.
const dom = new JSDOM("<!doctype html><div id=root></div>", {
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const globals = globalThis as Record<string, unknown>;
const keys = ["window", "document", "navigator", "HTMLElement", "IS_REACT_ACT_ENVIRONMENT"];
const saved = Object.fromEntries(keys.map((key) => [key, globals[key]]));
Object.assign(globals, {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  Node: dom.window.Node,
  getSelection: dom.window.getSelection.bind(dom.window),
  MutationObserver: dom.window.MutationObserver,
  IS_REACT_ACT_ENVIRONMENT: true,
});
afterAll(() => Object.assign(globals, saved));

const { act, createRef } = await import("react");
const { createRoot } = await import("react-dom/client");
const { PromptEditor } = await import("./PromptEditor");
const { keymap } = await import("@milkdown/kit/prose/keymap");
type Handle = import("./PromptEditor").PromptEditorHandle;

const settle = () => act(async () => new Promise((resolve) => setTimeout(resolve, 20)));
const key = (editable: HTMLElement, init: KeyboardEventInit) =>
  act(async () => {
    editable.dispatchEvent(new dom.window.KeyboardEvent("keydown", { bubbles: true, cancelable: true, ...init }));
  });

async function mount(props: Partial<import("./PromptEditor").PromptEditorProps> = {}) {
  const ref = createRef<Handle>();
  const changes: string[] = [];
  const root = createRoot(document.getElementById("root")!);
  await act(async () =>
    root.render(
      <PromptEditor ref={ref} value="" onChange={(markdown) => changes.push(markdown)} features={{}} {...props} />,
    ),
  );
  await settle();
  const editable = document.querySelector<HTMLElement>(".acpmux-md")!;
  return { ref, changes, root, editable, unmount: () => act(async () => root.unmount()) };
}

describe("PromptEditor", () => {
  test("typed text reaches onBeforeInput first; consumed text never lands in the editor", async () => {
    const seen: { data: string; empty: boolean; composing: boolean }[] = [];
    const view = await mount({
      onBeforeInput: (data, state) => {
        seen.push({ data, ...state });
        return data === "!" && state.empty;
      },
    });
    await act(async () => view.ref.current!.insertTyped("!"));
    expect(view.ref.current!.plainText()).toBe("");
    await act(async () => view.ref.current!.insertTyped("a"));
    await act(async () => view.ref.current!.insertTyped("!"));
    expect(view.ref.current!.plainText()).toBe("a!");
    expect(seen).toEqual([
      { data: "!", empty: true, composing: false },
      { data: "a", empty: true, composing: false },
      { data: "!", empty: false, composing: false },
    ]);
    await view.unmount();
  });

  test("text typed during IME composition is reported as composing", async () => {
    const seen: boolean[] = [];
    const view = await mount({ onBeforeInput: (_data, state) => (seen.push(state.composing), false) });
    await act(async () =>
      view.editable.dispatchEvent(new dom.window.CompositionEvent("compositionstart", { bubbles: true })),
    );
    await act(async () => view.ref.current!.insertTyped("!"));
    await act(async () =>
      view.editable.dispatchEvent(new dom.window.CompositionEvent("compositionend", { bubbles: true })),
    );
    expect(seen).toEqual([true]);
    await view.unmount();
  });

  test("a paste reaches onBeforeInput whole, so `!cmd` converts with its command", async () => {
    const seen: string[] = [];
    const view = await mount({ onBeforeInput: (data) => (seen.push(data), data.startsWith("!")) });
    await act(async () => view.ref.current!.pasteText("!npm test"));
    expect(seen).toEqual(["!npm test"]);
    expect(view.ref.current!.plainText()).toBe("");
    await view.unmount();
  });

  test("Enter submits, Cmd-Enter submits with cmd, and a surface that takes Enter stops it", async () => {
    const submits: [string, boolean][] = [];
    let takeEnter = false;
    const view = await mount({
      value: "ship **it**",
      onSubmit: (markdown, modifiers) => submits.push([markdown, modifiers.cmd]),
      onKeyDown: (event) => {
        if (takeEnter && event.key === "Enter") event.preventDefault();
      },
    });
    await key(view.editable, { key: "Enter" });
    await key(view.editable, { key: "Enter", metaKey: true });
    takeEnter = true;
    await key(view.editable, { key: "Enter" });
    expect(submits).toEqual([
      ["ship **it**", false],
      ["ship **it**", true],
    ]);
    await view.unmount();
  });

  test("plainText has no Markdown escaping or markers", async () => {
    const view = await mount({ value: "Make it **bold** and 2 * 3" });
    expect(view.ref.current!.plainText()).toBe("Make it bold and 2 * 3");
    await view.unmount();
  });

  test("the first user input is reported once", async () => {
    let first = 0;
    const view = await mount({ onFirstInput: () => (first += 1) });
    await act(async () => view.ref.current!.insertTyped("h"));
    await act(async () => view.ref.current!.insertTyped("i"));
    expect(first).toBe(1);
    await view.unmount();
  });

  test("a surface keymap runs before the editor's keys", async () => {
    const seen: string[] = [];
    const omnibar = keymap({ "Alt-Backspace": () => (seen.push("word"), true) });
    const view = await mount({ value: "a/b", features: { keymap: [omnibar] } });
    await key(view.editable, { key: "Backspace", altKey: true });
    expect(seen).toEqual(["word"]);
    await view.unmount();
  });

  test("focus asked before the editor exists is applied when it is ready", async () => {
    const ref = createRef<Handle>();
    const root = createRoot(document.getElementById("root")!);
    await act(async () => {
      root.render(<PromptEditor ref={ref} value="" onChange={() => {}} features={{}} />);
      ref.current?.focus();
    });
    await settle();
    expect(ref.current!.focused()).toBe(true);
    await act(async () => root.unmount());
  });
});
