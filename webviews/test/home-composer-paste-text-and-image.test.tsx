// https://github.com/manaflow-ai/cmux/issues/59851: a copy of text with an image beside it (a
// composer draft's Select All and Copy) pasted into Chief's composer as the image alone. WebKit
// withholds a paste's text/plain while the pasteboard holds file URLs and gives only the files and
// the HTML; the composer took the empty text for "only file names" and dropped the paste's text.
//
// The real composer and editor run in a DOM; the paste goes to the editor as WebKit sends it.
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
const emptyRect = () => ({ top: 0, bottom: 0, left: 0, right: 0, width: 0, height: 0, x: 0, y: 0, toJSON() {} });
Object.assign(dom.window.Range.prototype, {
  getClientRects: () => Object.assign([], { item: () => null }),
  getBoundingClientRect: emptyRect,
});
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

const { Composer } = await import("../src/pages/home-channels/Composer");
const { createStrings } = await import("../src/pages/shared/i18n");
const { htmlText, pastedPlainText } = await import("../src/agent-session/acpmux/pasteText");
const { pasteIsOnlyFileNames } = await import("../src/agent-session/acpmux/attachments");
const table = (await import("../src/pages/home-channels/generated/strings.json")).default;
type MarkdownFieldElement = import("../src/agent-session/acpmux/MarkdownField").MarkdownFieldElement;

const strings = createStrings(table, ["en"]);
/// The HTML the host writes beside a composer copy's text (AgentPaneComposerCopy.swift composerHTML).
const COMPOSER_HTML = `<span data-cmux-composer-copy="C1" style="white-space: pre-wrap">line one\n  line two</span>`;

async function settle() {
  for (let turn = 0; turn < 5; turn++) await act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
}

/// A paste as WebKit delivers one while the pasteboard holds a file: Files and HTML, no plain text.
function clipboard(files: File[], html: string, plain = "") {
  return {
    files,
    types: [...(files.length ? ["Files"] : []), ...(html ? ["text/html"] : []), ...(plain ? ["text/plain"] : [])],
    getData: (type: string) => (type === "text/html" ? html : type === "text/plain" ? plain : ""),
  } as unknown as DataTransfer;
}

const shot = () => new dom.window.File(["png"], "shot.png", { type: "image/png" }) as unknown as File;

test("a paste's text WebKit withheld for its files is read from its HTML, line ends kept", () => {
  expect(htmlText(COMPOSER_HTML)).toBe("line one\n  line two");
  expect(pastedPlainText(clipboard([shot()], COMPOSER_HTML))).toBe("line one\n  line two");
  // Plain text, when there is any, is the paste's; with no files the HTML is the field's own to read.
  expect(pastedPlainText(clipboard([shot()], COMPOSER_HTML, "as typed"))).toBe("as typed");
  expect(pastedPlainText(clipboard([], COMPOSER_HTML))).toBe("");
  // HTML that is only collapsed markup keeps collapsing; a hidden element is no text.
  expect(htmlText("<p>a   b</p><span hidden>meta</span>")).toBe("a b");
});

test("text beside the files is more than their names; a file manager's names alone are not", () => {
  expect(pasteIsOnlyFileNames(clipboard([shot()], COMPOSER_HTML))).toBe(false);
  expect(pasteIsOnlyFileNames(clipboard([shot()], ""))).toBe(true);
  expect(pasteIsOnlyFileNames(clipboard([shot()], `<img src="file:///tmp/shot.png">`))).toBe(true);
  expect(pasteIsOnlyFileNames(clipboard([shot()], "", "shot.png"))).toBe(true);
});

test("Chief's composer takes both the image and the text of a copy that holds both", async () => {
  const container = dom.window.document.getElementById("root")!;
  const uploads: string[] = [];
  const service = {
    async upload(_conversation: string, file: File) {
      uploads.push(file.name);
      return { type: "attachment", hash: file.name, name: file.name, mimeType: "image/png", byteCount: file.size };
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
  const element = [...container.querySelectorAll<MarkdownFieldElement>("*")].find((node) => node.acpmuxMarkdownField)!;
  const editable = container.querySelector<HTMLElement>('[contenteditable="true"]')!;
  await act(async () => element.acpmuxMarkdownField!.focus());
  const event = new dom.window.Event("paste", { bubbles: true, cancelable: true });
  Object.defineProperty(event, "clipboardData", { value: clipboard([shot()], COMPOSER_HTML) });
  await act(async () => {
    editable.dispatchEvent(event);
  });
  await settle();
  expect(uploads).toEqual(["shot.png"]);
  // The field keeps the line break as its own (a hard break in its markdown).
  const value = element.acpmuxMarkdownField!.value();
  expect(value).toContain("line one");
  expect(value).toContain("line two");
  await act(async () => root.unmount());
});
