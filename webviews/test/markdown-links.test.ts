// Links in the markdown editor, in the real editor (jsdom): reading (anchors, footnotes, broken
// marks), editing (popover, paste, reference-aware edits) and round-trip safety of link edits.
import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { TextSelection } from "@milkdown/kit/prose/state";
import type { MarkdownEditor as MarkdownEditorType } from "../src/pages/markdown/editor";
import type { ResolvedLink } from "../src/pages/markdown/links";

const saved = new Map<string, unknown>();
const DOM_GLOBALS = [
  "window",
  "document",
  "navigator",
  "Node",
  "Text",
  "HTMLElement",
  "Element",
  "DOMParser",
  "MutationObserver",
  "getComputedStyle",
  "requestAnimationFrame",
  "cancelAnimationFrame",
  "getSelection",
  "Range",
  "KeyboardEvent",
  "MouseEvent",
  "DocumentFragment",
];
let dom: JSDOM;
let editor: MarkdownEditorType;
const opened: string[] = [];
const scrolled: Element[] = [];
const resolved = new Map<string, ResolvedLink>();

beforeAll(async () => {
  dom = new JSDOM('<!doctype html><html><body><div id="root"></div></body></html>', { pretendToBeVisual: true });
  const win = dom.window as unknown as Record<string, unknown>;
  for (const key of DOM_GLOBALS) {
    saved.set(key, (globalThis as Record<string, unknown>)[key]);
    (globalThis as Record<string, unknown>)[key] = win[key];
  }
  (dom.window.Element.prototype as unknown as { scrollIntoView: () => void }).scrollIntoView = function (
    this: Element,
  ) {
    scrolled.push(this);
  };
  // jsdom has no layout: the popover asks for coordinates.
  (dom.window.Range.prototype as unknown as { getClientRects: () => unknown[] }).getClientRects = () => [];
  (dom.window.Range.prototype as unknown as { getBoundingClientRect: () => unknown }).getBoundingClientRect = () => ({
    left: 0,
    top: 0,
    right: 0,
    bottom: 0,
    width: 0,
    height: 0,
  });
  const { MarkdownEditor } = await import("../src/pages/markdown/editor");
  editor = new MarkdownEditor({
    root: dom.window.document.getElementById("root")!,
    host: {
      openLink: (href) => opened.push(href),
      imageURL: (src) => src,
      label: (key) => key,
      links: {
        resolved: (path) => resolved.get(path),
        requestLinks: () => {},
        listFiles: async (prefix) =>
          ["docs/", "docs/guide.md", "README.md"].filter((entry) => entry.startsWith(prefix)),
        linkLabel: (key) => key,
      },
    },
  });
  await editor.create();
});

afterAll(async () => {
  await editor?.destroy();
  for (const [key, value] of saved) {
    if (value === undefined) delete (globalThis as Record<string, unknown>)[key];
    else (globalThis as Record<string, unknown>)[key] = value;
  }
});

const view = () => editor.editorView()!;
const textPos = (needle: string) => {
  let found = -1;
  view().state.doc.descendants((node, pos) => {
    if (found < 0 && node.isText && node.text!.includes(needle)) found = pos + node.text!.indexOf(needle);
    return found < 0;
  });
  if (found < 0) throw new Error(`no ${needle}`);
  return found;
};
/** The position of the text node whose whole text is `text`. */
const nodeWithText = (text: string) => {
  let found = -1;
  view().state.doc.descendants((node, pos) => {
    if (found < 0 && node.isText && node.text === text) found = pos;
    return found < 0;
  });
  return found;
};
const click = (element: Element, init: MouseEventInit = {}) =>
  element.dispatchEvent(new dom.window.MouseEvent("click", { bubbles: true, cancelable: true, ...init }));

describe("following", () => {
  test("a plain click on a link edits; Cmd-click follows the href", () => {
    editor.load("See [the guide](docs/guide.md#setup) and <https://cmux.dev>.\n");
    opened.length = 0;
    const anchor = view().dom.querySelector("a")!;
    click(anchor);
    expect(opened).toEqual([]);
    click(anchor, { metaKey: true });
    expect(opened).toEqual(["docs/guide.md#setup"]);
  });

  test("in a read-only file a plain click follows", () => {
    editor.load("[x](https://example.com)\n");
    editor.setReadOnly(true);
    opened.length = 0;
    click(view().dom.querySelector("a")!);
    editor.setReadOnly(false);
    expect(opened).toEqual(["https://example.com"]);
  });

  test("reference links and autolinks are links like any other", () => {
    editor.load("A [ref][r], an <https://a.dev> and www.b.dev.\n\n[r]: https://r.dev\n");
    expect([...view().dom.querySelectorAll("a")].map((a) => a.getAttribute("href"))).toEqual([
      "https://r.dev",
      "https://a.dev",
      "http://www.b.dev",
    ]);
  });

  test("#anchors scroll to the heading by GitHub slug, repeats with -1", () => {
    editor.load("# Intro\n\n## Setup\n\ntext\n\n## Setup\n\nmore\n");
    scrolled.length = 0;
    expect(editor.scrollToAnchor("setup-1")).toBe(true);
    expect(scrolled.at(-1)?.textContent).toBe("Setup");
    expect(scrolled.at(-1)).toBe(view().dom.querySelectorAll("h2")[1]);
    expect(editor.scrollToAnchor("intro")).toBe(true);
    expect(editor.scrollToAnchor("missing")).toBe(false);
  });

  test("footnotes jump to the definition and back", () => {
    editor.load("Claim[^1] here.\n\n[^1]: The note.\n");
    scrolled.length = 0;
    const reference = view().dom.querySelector('sup[data-type="footnote_reference"]')!;
    click(reference, { metaKey: true });
    expect(scrolled.at(-1)?.getAttribute("data-type")).toBe("footnote_definition");
    click(view().dom.querySelector('[data-type="footnote_definition"] > dt')!);
    expect(scrolled.at(-1)).toBe(reference);
  });

  test("missing relative targets and anchors are marked broken", () => {
    resolved.set("there.md", { exists: true, path: "/w/there.md", kind: "markdown" });
    resolved.set("gone.md", { exists: false });
    editor.load("# Top\n\n[a](there.md) [b](gone.md) [c](#top) [d](#nope)\n");
    editor.refreshLinks();
    const broken = [...view().dom.querySelectorAll(".md-link-broken")].map((element) => element.textContent);
    expect(broken).toEqual(["b", "d"]);
  });
});

describe("editing", () => {
  test("Cmd-K on a selection links it; Enter applies, the block alone changes", () => {
    const text = "# Title\n\nPlain words here.\n\n- list\n";
    editor.load(text);
    const from = textPos("words");
    view().dispatch(view().state.tr.setSelection(TextSelection.create(view().state.doc, from, from + 5)));
    editor.openLinkPopover();
    const input = document.querySelector<HTMLInputElement>(".md-link-input")!;
    input.value = "docs/guide.md";
    input.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: "Enter", bubbles: true }));
    expect(document.querySelector(".md-link-popover")).toBe(null);
    expect(editor.snapshot().text).toBe("# Title\n\nPlain [words](docs/guide.md) here.\n\n- list\n");
  });

  test("Escape cancels the popover without a change", () => {
    const text = "Some text.\n";
    editor.load(text);
    editor.openLinkPopover();
    const input = document.querySelector<HTMLInputElement>(".md-link-input")!;
    input.value = "https://x.dev";
    input.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: "Escape", bubbles: true }));
    expect(document.querySelector(".md-link-popover")).toBe(null);
    expect(editor.snapshot().text).toBe(text);
  });

  test("the popover completes #headings and workspace paths", async () => {
    editor.load("# Getting Started\n\n## API\n\nx\n");
    editor.openLinkPopover();
    const input = document.querySelector<HTMLInputElement>(".md-link-input")!;
    input.value = "#get";
    input.dispatchEvent(new dom.window.Event("input"));
    await new Promise((resolve) => setTimeout(resolve, 0));
    expect([...document.querySelectorAll(".md-link-suggestions li")].map((li) => li.textContent)).toEqual([
      "#getting-started",
    ]);
    input.value = "docs/";
    input.dispatchEvent(new dom.window.Event("input"));
    await new Promise((resolve) => setTimeout(resolve, 0));
    expect([...document.querySelectorAll(".md-link-suggestions li")].map((li) => li.textContent)).toEqual([
      "docs/",
      "docs/guide.md",
    ]);
    input.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: "Escape", bubbles: true }));
  });

  const paste = (text: string) => {
    const event = new dom.window.Event("paste") as Event & { clipboardData: unknown };
    event.clipboardData = { getData: (type: string) => (type === "text/plain" ? text : "") };
    return view().someProp("handlePaste", (handler) => handler(view(), event as ClipboardEvent, null as never));
  };

  test("pasting a URL over a selection links it", () => {
    editor.load("Read the docs today.\n");
    const from = textPos("docs");
    view().dispatch(view().state.tr.setSelection(TextSelection.create(view().state.doc, from, from + 4)));
    expect(paste("https://cmux.dev/docs")).toBe(true);
    expect(editor.snapshot().text).toBe("Read the [docs](https://cmux.dev/docs) today.\n");
  });

  test("pasting a URL alone makes an autolink; other text is not linked whole", () => {
    editor.load("Link: here\n");
    const at = textPos("here") + 4;
    view().dispatch(view().state.tr.setSelection(TextSelection.create(view().state.doc, at)));
    expect(paste("https://cmux.dev")).toBe(true);
    expect(editor.snapshot().text).toBe("Link: here<https://cmux.dev>\n");
    // Text that is not one URL goes to the clipboard plugin (markdown paste): only a URL in it links.
    editor.load("Link: here\n");
    paste("two words https://x.dev");
    expect([...view().dom.querySelectorAll("a")].map((a) => a.textContent)).toEqual(["https://x.dev"]);
  });

  test("editing a reference link's text keeps the reference; a shortcut becomes full", () => {
    const text = "Use [guide][g] and [g] daily.\n\nOther.\n\n[g]: https://g.dev\n";
    editor.load(text);
    const at = textPos("guide") + 5;
    view().dispatch(view().state.tr.insertText(" book", at));
    expect(editor.snapshot().text).toBe("Use [guide book][g] and [g] daily.\n\nOther.\n\n[g]: https://g.dev\n");
    const gPos = nodeWithText("g");
    view().dispatch(view().state.tr.insertText("gee", gPos, gPos + 1));
    expect(editor.snapshot().text).toBe("Use [guide book][g] and [gee][g] daily.\n\nOther.\n\n[g]: https://g.dev\n");
  });

  test("a new URL on a reference link updates its definition and keeps the reference", async () => {
    const text = 'Use [guide][g] here.\n\nAlso [again][g].\n\nUntouched *para*.\n\n[g]: https://old.dev "T"\n';
    editor.load(text);
    const { applyLink, linkRangeAt } = await import("../src/pages/markdown/linkEditing");
    const range = linkRangeAt(view().state, textPos("guide") + 1)!;
    applyLink(view(), range.from, range.to, "https://new.dev", range.mark);
    expect(editor.snapshot().text).toBe(
      'Use [guide][g] here.\n\nAlso [again][g].\n\nUntouched *para*.\n\n[g]: https://new.dev "T"\n',
    );
    expect([...view().dom.querySelectorAll("a")].map((a) => a.getAttribute("href"))).toEqual([
      "https://new.dev",
      "https://new.dev",
    ]);
  });

  test("an edited inline link changes only its block", async () => {
    const text = "* star  \nlist\n\nSee [a](./a.md) now.\n\n| t | u |\n|---|---|\n| 1 | 2 |\n";
    editor.load(text);
    const { applyLink, linkRangeAt } = await import("../src/pages/markdown/linkEditing");
    const range = linkRangeAt(view().state, nodeWithText("a") + 1)!;
    expect(range.mark.attrs.href).toBe("./a.md");
    applyLink(view(), range.from, range.to, "./b.md#top", range.mark);
    expect(editor.snapshot().text).toBe(
      "* star  \nlist\n\nSee [a](./b.md#top) now.\n\n| t | u |\n|---|---|\n| 1 | 2 |\n",
    );
  });

  test("an empty URL removes the link", async () => {
    editor.load("x [y](z.md) w\n");
    const { applyLink, linkRangeAt } = await import("../src/pages/markdown/linkEditing");
    const range = linkRangeAt(view().state, textPos("y") + 1)!;
    applyLink(view(), range.from, range.to, "", range.mark);
    expect(editor.snapshot().text).toBe("x y w\n");
  });
});
