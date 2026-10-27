// Quote in Reply on selected message text (POLISH.md right-click contract): the app's native
// selection menu sends the page command `quoteSelection`, and the selection lands in the open
// composer as a Markdown quote, after what was already typed. A thread's composer takes it while
// the thread is open; a selection inside a composer is never quoted. In an empty composer the reply
// is typed below the quote, not inside it.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { Composer } from "../src/pages/home-channels/Composer";
import { QUOTE_EVENT, quoteSelection } from "../src/pages/home-channels/quoteSelection";
import table from "../src/pages/home-channels/generated/strings.json";
import { createStrings } from "../src/pages/shared/i18n";

let dom: JSDOM | undefined;
const roots: Root[] = [];
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function installDom(): Document {
  dom = new JSDOM("<!doctype html><html><body></body></html>", { pretendToBeVisual: true });
  Object.assign(dom.window, {
    ResizeObserver: class {
      observe() {}
      unobserve() {}
      disconnect() {}
    },
  });
  for (const key of [
    "window",
    "document",
    "navigator",
    "HTMLElement",
    "Element",
    "Node",
    "MouseEvent",
    "KeyboardEvent",
    "getComputedStyle",
    "requestAnimationFrame",
    "cancelAnimationFrame",
    "IS_REACT_ACT_ENVIRONMENT",
  ])
    saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    Node: dom.window.Node,
    MouseEvent: dom.window.MouseEvent,
    KeyboardEvent: dom.window.KeyboardEvent,
    getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
    requestAnimationFrame: (run: (time: number) => void) => setTimeout(() => run(0), 0),
    cancelAnimationFrame: (id: number) => clearTimeout(id),
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  // ProseMirror scrolls a focused insertion into view; jsdom has no layout.
  const box = () => new dom!.window.DOMRect(0, 0, 100, 20);
  Object.assign(dom.window.Range.prototype, {
    getClientRects: () => Object.assign([box()], { item: () => box() }),
    getBoundingClientRect: box,
  });
  dom.window.scrollBy = () => {};
  return dom.window.document;
}

afterEach(() => {
  for (const root of roots.splice(0)) act(() => root.unmount());
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

const strings = createStrings(table, ["en"]);

/** A composer inside `scope` (the main column or the thread sheet), with `typed` already in it. */
async function composer(doc: Document, scope: string, typed = "") {
  const host = doc.createElement("div");
  host.className = scope;
  doc.body.append(host);
  const root = createRoot(host);
  roots.push(root);
  await act(async () => {
    root.render(
      <Composer
        strings={strings}
        placeholder="Message"
        label="Message"
        onSend={async () => true}
        initialValue={typed}
      />,
    );
  });
  return host;
}

function message(doc: Document, text: string): HTMLElement {
  const node = doc.createElement("p");
  node.className = "hc-msg-text";
  node.textContent = text;
  doc.body.prepend(node);
  return node;
}

function select(node: Node) {
  const doc = node.ownerDocument!;
  const range = doc.createRange();
  range.selectNodeContents(node);
  const selection = doc.getSelection()!;
  selection.removeAllRanges();
  selection.addRange(range);
}

const field = (host: HTMLElement) => host.querySelector<HTMLElement>(".hc-composer-field")!;
const content = (host: HTMLElement) => field(host).querySelector<HTMLElement>("[contenteditable]")!;

test("Quote in Reply puts the selected lines in the main composer as a quote, after the draft", async () => {
  const doc = installDom();
  const main = await composer(doc, "lg-main-compose", "my draft");
  select(message(doc, "Ship it\nafter the review"));

  await act(async () => {
    expect(quoteSelection(doc)).toBe(true);
  });
  const quote = field(main).querySelector("blockquote");
  expect(quote?.textContent).toContain("Ship it");
  expect(quote?.textContent).toContain("after the review");
  expect([...content(main).children].map((node) => node.tagName)).toEqual(["P", "BLOCKQUOTE", "P"]);
  expect(content(main).firstElementChild?.textContent).toBe("my draft");
});

test("an open thread's composer takes the quote, and text selected in a composer is never quoted", async () => {
  const doc = installDom();
  const main = await composer(doc, "lg-main-compose");
  const sheet = await composer(doc, "lg-sheet");
  select(message(doc, "Root question"));
  await act(async () => {
    expect(quoteSelection(doc)).toBe(true);
  });
  expect(field(sheet).querySelector("blockquote")?.textContent).toContain("Root question");
  expect(field(main).querySelector("blockquote")).toBeNull();

  select(field(main));
  expect(quoteSelection(doc)).toBe(false);
});

test("in an empty composer the reply is typed below the quote, not inside it", async () => {
  const doc = installDom();
  const main = await composer(doc, "lg-main-compose");
  select(message(doc, "Ship it"));
  await act(async () => {
    expect(quoteSelection(doc)).toBe(true);
  });
  type Field = HTMLElement & { acpmuxMarkdownField?: { insertTyped(text: string): void } };
  const editor = [...main.querySelectorAll<Field>("*")].find((node) => node.acpmuxMarkdownField);
  await act(async () => editor!.acpmuxMarkdownField!.insertTyped("Agreed"));
  expect(field(main).querySelector("blockquote")?.textContent).not.toContain("Agreed");
  expect(field(main).textContent).toContain("Agreed");
});

test("several quotes keep the draft and the order they were picked", async () => {
  const doc = installDom();
  const main = await composer(doc, "lg-main-compose", "my draft");
  for (const text of ["First quote", "Second quote"]) {
    select(message(doc, text));
    await act(async () => {
      expect(quoteSelection(doc)).toBe(true);
    });
  }
  expect(content(main).firstElementChild?.textContent).toBe("my draft");
  expect([...field(main).querySelectorAll("blockquote")].map((node) => node.textContent)).toEqual([
    "First quote",
    "Second quote",
  ]);
});

function editorHandle(host: HTMLElement) {
  type Field = HTMLElement & {
    acpmuxMarkdownField?: import("../src/agent-session/acpmux/MarkdownField").MarkdownFieldHandle;
  };
  return [...host.querySelectorAll<Field>("*")].find((node) => node.acpmuxMarkdownField)!.acpmuxMarkdownField!;
}

async function quoteAtComposer(host: HTMLElement, text: string) {
  await act(async () =>
    host.querySelector(".hc-composer")!.dispatchEvent(new dom!.window.CustomEvent(QUOTE_EVENT, { detail: text })),
  );
}

test("a focused caret inserts the quote between draft parts, with the reply outside the quote", async () => {
  const doc = installDom();
  const main = await composer(doc, "lg-main-compose", "before after");
  const editor = editorHandle(main);
  await act(async () => {
    editor.focus();
    editor.writeText("before after", 7, 7);
  });
  await quoteAtComposer(main, "Selected message");
  expect([...content(main).children].map((node) => node.tagName)).toEqual(["P", "BLOCKQUOTE", "P", "P"]);
  await act(async () => editor.insertTyped("My reply "));
  expect(content(main).firstElementChild?.textContent).toBe("before ");
  expect(content(main).querySelector("blockquote")?.textContent).toBe("Selected message");
  expect(content(main).children[2]?.textContent).toBe("My reply ");
  expect(content(main).lastElementChild?.textContent).toBe("after");
});

test("an unfocused quote appends outside an existing quote, and one Undo restores the draft", async () => {
  const doc = installDom();
  const main = await composer(doc, "lg-main-compose", "**Draft**\n\n> Earlier quote");
  const editor = editorHandle(main);
  await quoteAtComposer(main, "New quote");
  expect(content(main).querySelector("strong")?.textContent).toBe("Draft");
  expect(content(main).querySelectorAll("blockquote").length).toBe(2);
  expect(content(main).querySelector("blockquote blockquote")).toBeNull();
  expect(content(main).lastElementChild?.tagName).toBe("P");
  await act(async () => editor.undo());
  expect(content(main).querySelectorAll("blockquote").length).toBe(1);
  expect(editor.value()).toBe("**Draft**\n\n> Earlier quote");
});

test("a selected draft is retained instead of replaced by the quote", async () => {
  const doc = installDom();
  const main = await composer(doc, "lg-main-compose", "Keep the whole draft");
  const editor = editorHandle(main);
  await act(async () => {
    editor.focus();
    editor.selectAll();
  });
  await quoteAtComposer(main, "New quote");
  expect(content(main).firstElementChild?.textContent).toBe("Keep the whole draft");
  expect(content(main).querySelector("blockquote")?.textContent).toBe("New quote");
});
