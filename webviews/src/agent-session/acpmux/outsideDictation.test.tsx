import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { DictationButton } from "./DictationButton";
import type { Dictation } from "./dictation";
import { applyHostEvent } from "./pageHost";
import { settleReact } from "../../../test/support/domTeardown";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

afterEach(async () => {
  if (root) await act(async () => root!.unmount());
  root = undefined;
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

test("focusing a composer never watches the microphone", async () => {
  const watches: boolean[] = [];
  const { doc, prompt } = await mount(watches);
  await act(async () => prompt.focus());
  await act(async () => (doc.getElementById("elsewhere") as HTMLInputElement).focus());
  await act(async () => prompt.focus());
  expect(watches).toEqual([]);
});

test("another app's microphone events leave the mic idle and preserve typing", async () => {
  const { prompt, button } = await mount([]);
  await act(async () => prompt.focus());
  const title = button.getAttribute("title");
  for (const name of ["Meeting", "Dictation app"]) {
    await act(async () => {
      applyHostEvent({ kind: "micActivity", value: { active: true, name, metered: true } });
      applyHostEvent({ kind: "micLevel", value: { level: 0.8 } });
    });
    expect(button.getAttribute("aria-pressed")).toBe("false");
    expect(button.getAttribute("data-state")).toBe("idle");
    expect(button.getAttribute("title")).toBe(title);
    expect(button.querySelector(".acpmux-mic-outside, .acpmux-mic-level")).toBeNull();
    expect(button.ownerDocument.activeElement).toBe(prompt);
  }
});
