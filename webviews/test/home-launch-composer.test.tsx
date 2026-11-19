// Home's composer takes keys before the page knows which conversation it writes to (LaunchComposer.tsx,
// startup-tti lane): what the person typed there is the first open conversation's composer text, once;
// the next conversation's composer starts empty. Nothing is sent from the launch composer.
//
// The real composer and editor run in a DOM, as in home-composer-undo.test.tsx.
// The real composer and editor run in a DOM; a key-down goes to the editor as WebKit sends it.
import { afterAll, expect, test } from "bun:test";
import { settleReact } from "./support/domTeardown";
import { act } from "react";
import { createRoot } from "react-dom/client";
import { JSDOM } from "jsdom";

const dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", {
  url: "http://localhost/",
  pretendToBeVisual: true,
});
Object.assign(dom.window, {
  ResizeObserver: class {
    observe() {}
    unobserve() {}
    disconnect() {}
  },
});
// A DOM with no layout: the editor's scroll into view measures empty rectangles.
const emptyRect = () => ({ top: 0, bottom: 0, left: 0, right: 0, width: 0, height: 0, x: 0, y: 0, toJSON() {} });
Object.assign(dom.window.Range.prototype, {
  getClientRects: () => Object.assign([], { item: () => null }),
  getBoundingClientRect: emptyRect,
});
// The app's web view runs on a Mac: Mod is Command there.
Object.defineProperty(dom.window.navigator, "platform", { configurable: true, value: "MacIntel" });
const scope = globalThis as Record<string, unknown>;
const keys = [
  "window",
  "document",
  "navigator",
  "HTMLElement",
  "Element",
  "Node",
  "File",
  "FileReader",
  "MouseEvent",
  "KeyboardEvent",
  "InputEvent",
  "getComputedStyle",
  "requestAnimationFrame",
  "cancelAnimationFrame",
  "IS_REACT_ACT_ENVIRONMENT",
];
const saved = new Map(keys.map((key) => [key, scope[key]]));
Object.assign(scope, {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  Element: dom.window.Element,
  Node: dom.window.Node,
  File: dom.window.File,
  FileReader: dom.window.FileReader,
  MouseEvent: dom.window.MouseEvent,
  KeyboardEvent: dom.window.KeyboardEvent,
  InputEvent: dom.window.InputEvent,
  getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
  requestAnimationFrame: (run: (time: number) => void) => setTimeout(() => run(0), 0),
  cancelAnimationFrame: (id: number) => clearTimeout(id),
  IS_REACT_ACT_ENVIRONMENT: true,
});
afterAll(async () => {
  await settleReact();
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  dom.window.close();
});

const { LaunchMain, OpenComposer } = await import("../src/pages/home-channels/LaunchComposer");
const { createStrings } = await import("../src/pages/shared/i18n");
const table = (await import("../src/pages/home-channels/generated/strings.json")).default;
type MarkdownFieldElement = import("../src/agent-session/acpmux/MarkdownField").MarkdownFieldElement;

const strings = createStrings(table, ["en"]);

async function settle() {
  for (let turn = 0; turn < 5; turn++) await act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
}

async function show(node: import("react").ReactNode) {
  const container = dom.window.document.getElementById("root")!;
  const root = createRoot(container);
  await act(async () => root.render(node));
  await settle();
  const field = () => {
    const found = [...container.querySelectorAll<MarkdownFieldElement>("*")].find((each) => each.acpmuxMarkdownField);
    if (!found) throw new Error("no prompt field");
    return found.acpmuxMarkdownField!;
  };
  return {
    text: () => field().value(),
    async type(text: string) {
      await act(async () => {
        field().focus();
        field().insertText(text);
      });
      await settle();
    },
    unmount: () => act(async () => root.unmount()),
  };
}

test("text typed before a conversation opens is the first open composer's text, once", async () => {
  const sends: string[] = [];
  const launch = await show(<LaunchMain strings={strings} />);
  await launch.type("hello Chief");
  await launch.unmount();

  const first = await show(
    <OpenComposer
      strings={strings}
      placeholder="Message"
      label="Message"
      onSend={async (text) => !!sends.push(text)}
    />,
  );
  expect(first.text()).toBe("hello Chief");
  await first.unmount();
  expect(sends).toEqual([]);

  const second = await show(
    <OpenComposer strings={strings} placeholder="Message" label="Message" onSend={async () => true} />,
  );
  expect(second.text()).toBe("");
  await second.unmount();
});
