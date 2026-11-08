// https://github.com/manaflow-ai/cmux/issues/38148: Cmd-Z and Shift-Cmd-Z in Chief's composer undo and
// redo the text and the staged files on one line, newest first, as a native text field undoes its
// edits. A file removed by accident comes back with Cmd-Z; before, the tray's files were outside the
// editor's history and nothing brought one back.
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

const { Composer } = await import("../src/pages/home-channels/Composer");
const { createStrings } = await import("../src/pages/shared/i18n");
const table = (await import("../src/pages/home-channels/generated/strings.json")).default;
type MarkdownFieldElement = import("../src/agent-session/acpmux/MarkdownField").MarkdownFieldElement;

const strings = createStrings(table, ["en"]);

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
  const root = createRoot(container);
  await act(async () => {
    root.render(
      <Composer
        strings={strings}
        placeholder="Message"
        label="Message"
        onSend={async () => true}
        attachments={{ service: service as never, conversation: "c1" }}
      />,
    );
  });
  await settle();
  const fieldElement = (): MarkdownFieldElement => {
    const found = [...container.querySelectorAll<MarkdownFieldElement>("*")].find((node) => node.acpmuxMarkdownField);
    if (!found) throw new Error("no prompt field");
    return found;
  };
  const field = () => fieldElement().acpmuxMarkdownField!;
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
    async remove(name: string) {
      const button = container.querySelector<HTMLButtonElement>(
        `button[aria-label="${strings.format("attach.remove", name)}"]`,
      )!;
      await act(async () => button.click());
      await settle();
    },
    async key(shift: boolean) {
      await act(async () => {
        editable().dispatchEvent(
          new dom.window.KeyboardEvent("keydown", {
            key: shift ? "Z" : "z",
            code: "KeyZ",
            keyCode: 90,
            metaKey: true,
            shiftKey: shift,
            bubbles: true,
            cancelable: true,
          }),
        );
      });
      await settle();
    },
    unmount: () => act(async () => root.unmount()),
  };
}

test("Cmd-Z and Shift-Cmd-Z undo and redo the text and the staged files, newest first", async () => {
  const composer = await mount();
  await composer.type("hello");
  await composer.pick("a.txt");
  await composer.type(" world");
  await composer.remove("a.txt");
  expect(composer.text()).toBe("hello world");
  expect(composer.files()).toEqual([]);

  const undo = () => composer.key(false);
  const redo = () => composer.key(true);

  // The removed file comes back first, then the text typed after it was added, then the file's add.
  await undo();
  expect(composer.files()).toEqual(["a.txt"]);
  expect(composer.text()).toBe("hello world");
  await undo();
  expect(composer.text()).toBe("hello");
  expect(composer.files()).toEqual(["a.txt"]);
  await undo();
  expect(composer.files()).toEqual([]);
  expect(composer.text()).toBe("hello");
  await undo();
  expect(composer.text()).toBe("");

  // Redo walks the same line forward.
  await redo();
  expect(composer.text()).toBe("hello");
  expect(composer.files()).toEqual([]);
  await redo();
  expect(composer.files()).toEqual(["a.txt"]);
  await redo();
  expect(composer.text()).toBe("hello world");
  expect(composer.files()).toEqual(["a.txt"]);
  await redo();
  expect(composer.files()).toEqual([]);
  await composer.unmount();
});

test("a file put back by undo keeps its stored upload, and a new edit ends the redo", async () => {
  const composer = await mount();
  await composer.pick("b.txt");
  await composer.remove("b.txt");
  await composer.key(false);
  expect(composer.files()).toEqual(["b.txt"]);
  // Uploaded once: the stored part came back with it.
  expect(composer.uploads).toEqual(["b.txt"]);

  await composer.key(false);
  expect(composer.files()).toEqual([]);
  await composer.type("x");
  await composer.key(true);
  // Typing after the undo ended its redo, as in a text field: the file stays out.
  expect(composer.files()).toEqual([]);
  expect(composer.text()).toBe("x");
  await composer.unmount();
});
