// The outside-dictation mark (outsideDictation.ts): the host is asked to watch the microphone only
// while a composer has the keyboard, the mark draws in the mic's own place, and the prompt keeps
// focus and every key while it shows.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { DictationButton } from "./DictationButton";
import type { Dictation } from "./dictation";
import { setOutsideDictation } from "./outsideDictation";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

afterEach(async () => {
  if (root) await act(async () => root!.unmount());
  root = undefined;
  setOutsideDictation({ active: false });
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

const idle: Dictation = {
  state: "idle",
  notice: null,
  toggle() {},
  finish() {},
  cancel() {},
  openSettings() {},
  dismiss() {},
};

async function mount(watches: boolean[]) {
  dom = new JSDOM(
    "<!doctype html><html><body><form><textarea></textarea><main id=root></main></form><input id=elsewhere></body></html>",
  );
  for (const key of ["window", "document", "navigator", "Node", "HTMLElement", "Element", "IS_REACT_ACT_ENVIRONMENT"])
    saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  dom.window.document.hasFocus = () => true;
  (
    dom.window as unknown as { cmuxAcpmuxActions: Record<string, (params: Record<string, unknown>) => unknown> }
  ).cmuxAcpmuxActions = {
    "dictation.watchMicrophone": (params) => {
      watches.push(params.on === true);
      return {};
    },
    "dictation.sources": () => ({ sources: [] }),
  };
  await act(async () => {
    root = createRoot(dom!.window.document.getElementById("root")!);
    root.render(<DictationButton dictation={idle} />);
  });
  const doc = dom.window.document;
  return { doc, prompt: doc.querySelector("textarea")!, button: doc.querySelector("button")! };
}

test("the host watches only while the composer has the keyboard", async () => {
  const watches: boolean[] = [];
  const { doc, prompt } = await mount(watches);
  expect(watches).toEqual([]);
  await act(async () => prompt.focus());
  expect(watches).toEqual([true]);
  await act(async () => (doc.getElementById("elsewhere") as HTMLInputElement).focus());
  expect(watches).toEqual([true, false]);
});

test("another app's dictation draws in the mic's place and leaves the prompt focused", async () => {
  const { prompt, button } = await mount([]);
  await act(async () => prompt.focus());
  expect(button.getAttribute("data-outside")).toBeNull();
  await act(async () => setOutsideDictation({ active: true, bundleId: "com.openai.codex", name: "ChatGPT" }));
  expect(button.getAttribute("data-outside")).toBe("true");
  expect(button.querySelector(".acpmux-mic-outside")).not.toBeNull();
  // The glyph stays in the tree (hidden by CSS), so the button never re-lays out.
  expect(button.querySelector("svg")).not.toBeNull();
  expect(button.getAttribute("title")).toContain("ChatGPT");
  expect(button.ownerDocument.activeElement).toBe(prompt);
  await act(async () => setOutsideDictation({ active: false }));
  expect(button.getAttribute("data-outside")).toBeNull();
});

test("an unfocused composer shows nothing even while another app listens", async () => {
  const { button } = await mount([]);
  await act(async () => setOutsideDictation({ active: true, name: "ChatGPT" }));
  expect(button.getAttribute("data-outside")).toBeNull();
});
