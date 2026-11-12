// The outside-dictation mark (outsideDictation.ts): the host is asked to watch the microphone only
// while a composer has the keyboard, the mark draws in the mic's own place, and the prompt keeps
// focus and every key while it shows. Metered, its bars follow the host's `micLevel`.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { DictationButton } from "./DictationButton";
import type { Dictation } from "./dictation";
import { readOutsideLevel, setOutsideDictation, setOutsideLevel } from "./outsideDictation";
import { settleReact } from "../../../test/support/domTeardown";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

afterEach(async () => {
  if (root) await act(async () => root!.unmount());
  root = undefined;
  setOutsideDictation({ active: false });
  await settleReact();
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

const levels = (button: Element) =>
  [...button.querySelectorAll(".acpmux-mic-level > [data-bar]")].map((bar) =>
    Number((bar as HTMLElement).style.getPropertyValue("--level")),
  );

test("micLevel feeds the outside ring only while the host meters", () => {
  setOutsideLevel({ level: 0.5 });
  expect(readOutsideLevel().every((sample) => sample === 0)).toBe(true);
  setOutsideDictation({ active: true, name: "ChatGPT" });
  setOutsideLevel({ level: 0.5 });
  expect(readOutsideLevel().every((sample) => sample === 0)).toBe(true);
  setOutsideDictation({ active: true, name: "ChatGPT", metered: true });
  setOutsideLevel({ level: 0.5 });
  setOutsideLevel({ level: 2 });
  setOutsideLevel({ level: "loud" });
  expect(readOutsideLevel().slice(-2)).toEqual([0.5, 1]);
  // Unmetered or inactive, the ring clears.
  setOutsideDictation({ active: true, name: "ChatGPT" });
  expect(readOutsideLevel().every((sample) => sample === 0)).toBe(true);
  setOutsideDictation({ active: true, name: "ChatGPT", metered: true });
  setOutsideLevel({ level: 0.4 });
  setOutsideDictation({ active: false, metered: true });
  expect(readOutsideLevel().every((sample) => sample === 0)).toBe(true);
});

test("metered, the mark draws the measured level as bars; unmetered, the drawn pulse", async () => {
  const { doc, prompt, button } = await mount([]);
  await act(async () => prompt.focus());
  await act(async () => setOutsideDictation({ active: true, name: "ChatGPT", metered: true }));
  expect(button.querySelector(".acpmux-mic-outside")).toBeNull();
  expect(levels(button)).toEqual([0, 0, 0, 0]);
  await act(async () => {
    setOutsideLevel({ level: 0.2 });
    setOutsideLevel({ level: 0.6 });
  });
  const [, , older, newest] = levels(button);
  expect(older).toBeGreaterThan(0);
  expect(newest).toBeGreaterThan(0);
  expect(button.getAttribute("title")).toContain("ChatGPT");
  expect(button.ownerDocument.activeElement).toBe(prompt);
  await act(async () => setOutsideDictation({ active: true, name: "ChatGPT" }));
  expect(button.querySelector(".acpmux-mic-level")).toBeNull();
  expect(button.querySelector(".acpmux-mic-outside")).not.toBeNull();
  // Metered again, then the composer loses the keyboard: the page stops watching and the ring clears.
  await act(async () => {
    setOutsideDictation({ active: true, name: "ChatGPT", metered: true });
    setOutsideLevel({ level: 0.7 });
  });
  expect(readOutsideLevel().at(-1)).toBe(0.7);
  await act(async () => (doc.getElementById("elsewhere") as HTMLInputElement).focus());
  expect(readOutsideLevel().every((sample) => sample === 0)).toBe(true);
  expect(button.getAttribute("data-outside")).toBeNull();
});
