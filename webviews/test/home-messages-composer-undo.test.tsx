// https://github.com/manaflow-ai/cmux/issues/38148, Home's Chief composer (home-messages
// MessageComposer, the composer of Home's Messages view and the Chief panel): Cmd-Z and Shift-Cmd-Z undo
// and redo the text and the staged files on one line, newest first, as the Channels composer does
// (home-composer-undo.test.tsx). Before, a file removed by accident was gone: its tray is outside the
// editor's history.
//
// The real composer and editor run in a DOM; a key-down goes to the editor as WebKit sends it.
import { afterAll, expect, test } from "bun:test";
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
afterAll(() => {
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  dom.window.close();
});

const { MessageComposer } = await import("../src/pages/home-messages/transcript/MessageComposer");
const { createTranscriptStrings } = await import("../src/pages/home-messages/transcript/strings");
type Handle = import("../src/pages/home-messages/transcript/MessageComposer").MessageComposerHandle;
type MarkdownFieldElement = import("../src/agent-session/acpmux/MarkdownField").MarkdownFieldElement;

const strings = createTranscriptStrings(["en"]);

async function settle() {
  for (let turn = 0; turn < 5; turn++) await act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
}

async function mount() {
  const container = dom.window.document.getElementById("root")!;
  const uploads: string[] = [];
  const service = {
    async upload(_conversation: string, file: File) {
      uploads.push(file.name);
      return { type: "attachment", hash: file.name, name: file.name, mimeType: "text/plain", byteCount: file.size };
    },
  };
  let handle: Handle | null = null;
  const root = createRoot(container);
  await act(async () => {
    root.render(
      <MessageComposer
        strings={strings}
        sendEnabled
        onSend={async () => true}
        attachments={{ service: service as never, conversation: "c1" }}
        ref={(value) => void (handle = value)}
      />,
    );
  });
  await settle();
  const field = () => {
    const found = [...container.querySelectorAll<MarkdownFieldElement>("*")].find((node) => node.acpmuxMarkdownField);
    if (!found) throw new Error("no prompt field");
    return found.acpmuxMarkdownField!;
  };
  const editable = () => container.querySelector<HTMLElement>('[contenteditable="true"]')!;
  return {
    uploads,
    text: () => field().value(),
    files: () => [...container.querySelectorAll(".hc-tray-item .hc-att-name")].map((node) => node.textContent),
    async type(text: string) {
      await act(async () => {
        field().focus();
        field().insertText(text);
      });
      await settle();
    },
    async pick(name: string) {
      const picker = container.querySelector<HTMLInputElement>("input[type=file]")!;
      Object.defineProperty(picker, "files", {
        configurable: true,
        value: [new dom.window.File(["x"], name, { type: "text/plain" })],
      });
      await act(async () => {
        picker.dispatchEvent(new dom.window.Event("change", { bubbles: true }));
      });
      await settle();
    },
    /// A click on the file's remove button, as WebKit sends it (its mousedown keeps the keyboard in the prompt).
    async remove(name: string) {
      const item = [...container.querySelectorAll(".hc-tray-item")].find(
        (node) => node.querySelector(".hc-att-name")?.textContent === name,
      )!;
      const button = item.querySelector<HTMLButtonElement>("button")!;
      const down = new dom.window.MouseEvent("mousedown", { bubbles: true, cancelable: true });
      await act(async () => {
        button.dispatchEvent(down);
        button.click();
      });
      await settle();
      return down.defaultPrevented;
    },
    async quote(text: string) {
      await act(async () => {
        handle!.quote(text);
      });
      await settle();
    },
    async key(shift: boolean, key = shift ? "Z" : "z") {
      const target = dom.window.document.activeElement ?? dom.window.document.body;
      await act(async () => {
        target.dispatchEvent(
          new dom.window.KeyboardEvent("keydown", {
            key,
            code: `Key${key.toUpperCase()}`,
            keyCode: key.toUpperCase().charCodeAt(0),
            metaKey: true,
            shiftKey: shift,
            bubbles: true,
            cancelable: true,
          }),
        );
      });
      await settle();
    },
    async menu(inputType: "historyUndo" | "historyRedo") {
      await act(async () => {
        editable().dispatchEvent(
          new dom.window.InputEvent("beforeinput", { inputType, bubbles: true, cancelable: true }),
        );
      });
      await settle();
    },
    unmount: () => act(async () => root.unmount()),
  };
}

test("Chief: Cmd-Z and Shift-Cmd-Z undo and redo the text and the staged files, newest first", async () => {
  const composer = await mount();
  await composer.type("hello");
  await composer.pick("a.txt");
  await composer.type(" world");
  expect(await composer.remove("a.txt")).toBe(true);
  expect(composer.files()).toEqual([]);

  await composer.key(false);
  expect(composer.files()).toEqual(["a.txt"]);
  expect(composer.text()).toBe("hello world");
  // Put back with its finished upload: uploaded once.
  expect(composer.uploads).toEqual(["a.txt"]);
  await composer.key(false);
  expect(composer.text()).toBe("hello");
  expect(composer.files()).toEqual(["a.txt"]);
  await composer.key(false);
  expect(composer.files()).toEqual([]);
  await composer.key(false);
  expect(composer.text()).toBe("");

  await composer.key(true);
  expect(composer.text()).toBe("hello");
  await composer.key(true);
  expect(composer.files()).toEqual(["a.txt"]);
  await composer.key(true);
  expect(composer.text()).toBe("hello world");
  await composer.key(true);
  expect(composer.files()).toEqual([]);
  await composer.unmount();
});

test("Chief: Edit > Undo brings a removed file back; a new edit ends the redo", async () => {
  const composer = await mount();
  await composer.type("draft");
  await composer.pick("d.txt");
  await composer.remove("d.txt");
  await composer.menu("historyUndo");
  expect(composer.files()).toEqual(["d.txt"]);
  expect(composer.text()).toBe("draft");
  await composer.key(false);
  expect(composer.files()).toEqual([]);
  // A quote is an edit: the file's add stays undone.
  await composer.quote("q");
  await composer.key(true);
  expect(composer.files()).toEqual([]);
  await composer.unmount();
});
