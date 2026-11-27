// User, 2026-10-31: "cmd f doesnt work in markdown". The markdown page now takes the app's shared
// find commands (Cmd-F, Cmd-G, Shift-Cmd-G, Cmd-E, Hide Find Bar) and searches what it shows: the
// rendered document's text in rich mode (a match may span bold or a link inside one block, never
// two blocks), the text area's lines in source mode. Every match is highlighted, the active one
// apart; next and previous wrap; Escape clears the highlights and gives the document the keyboard.
import { act } from "react";
import { afterAll, beforeEach, expect, test } from "bun:test";
import { installDom } from "../src/pages/settings/testDom";
import { EditorFind } from "../src/pages/editor/editorFind";
import {
  MARKDOWN_FIND_ACTIVE_HIGHLIGHT,
  MARKDOWN_FIND_HIGHLIGHT,
  markdownFindTarget,
} from "../src/pages/markdown/markdownFind";

const restore = installDom();
afterAll(() => restore());
const { createRoot } = await import("react-dom/client");
const { MarkdownFindBar } = await import("../src/pages/markdown/MarkdownFindBar");

/** A stand-in for the CSS custom highlight registry jsdom lacks: what was painted, as text. */
const painted = new Map<string, string[]>();
class FakeHighlight {
  priority = 0;
  readonly ranges: Range[];
  constructor(...ranges: Range[]) {
    this.ranges = ranges;
  }
}
(globalThis as Record<string, unknown>).Highlight = FakeHighlight;
// jsdom has no layout: a range measures as an empty box at the top (WebKit measures it).
const RangeClass = (window as unknown as { Range: { prototype: Record<string, unknown> } }).Range;
RangeClass.prototype.getBoundingClientRect ??= () => ({ top: 0, bottom: 0, left: 0, right: 0, width: 0, height: 0 });
(globalThis as Record<string, unknown>).CSS = {
  highlights: {
    set: (name: string, value: FakeHighlight) =>
      painted.set(
        name,
        value.ranges.map((range) => range.toString()),
      ),
    delete: (name: string) => painted.delete(name),
  },
};

beforeEach(() => {
  painted.clear();
  document.body.innerHTML = "";
});

function page(html: string, mode: "rich" | "source" = "rich", source = "") {
  document.body.innerHTML = `<div class="md-page"><main class="md-scroll"><div class="md-doc"><div contenteditable="true">${html}</div></div>${
    mode === "source" ? `<textarea class="md-source"></textarea>` : ""
  }</main></div>`;
  const textarea = document.querySelector<HTMLTextAreaElement>(".md-source");
  if (textarea) textarea.value = source;
  const find = new EditorFind();
  find.attach(
    markdownFindTarget({
      mode: () => mode,
      doc: () => document.querySelector(".md-doc"),
      source: () => textarea,
      scroller: () => document.querySelector(".md-scroll"),
    }),
  );
  return find;
}

test("Cmd-F finds every match in the rendered document, across formatting inside one block", () => {
  const find = page(
    "<h1>Release notes</h1><p>The <strong>rel</strong>ease ships today.</p><ul><li>release one</li><li>Release two</li></ul>",
  );
  find.show();
  expect(find.getState().open).toBe(true);
  find.setQuery("release");
  expect(find.getState().matches.length).toBe(4);
  expect(find.getState().active).toBe(0);
  expect(painted.get(MARKDOWN_FIND_ACTIVE_HIGHLIGHT)).toEqual(["Release"]);
  // The match over `<strong>rel</strong>ease` is one range spanning both nodes.
  expect(painted.get(MARKDOWN_FIND_HIGHLIGHT)).toEqual(["release", "release", "Release"]);
});

test("a match never runs from one block into the next", () => {
  const find = page("<p>end of one</p><p>start of two</p>");
  find.show("onestart");
  expect(find.getState().matches.length).toBe(0);
  find.setQuery("one");
  expect(find.getState().matches.length).toBe(1);
});

test("next and previous step through the matches and wrap", () => {
  const find = page("<p>alpha beta alpha</p><p>alpha</p>");
  find.show("alpha");
  const active = () => find.getState().active;
  expect(active()).toBe(0);
  find.next();
  expect(active()).toBe(1);
  find.next();
  expect(active()).toBe(2);
  find.next();
  expect(active()).toBe(0);
  find.previous();
  expect(active()).toBe(2);
  expect(painted.get(MARKDOWN_FIND_ACTIVE_HIGHLIGHT)).toEqual(["alpha"]);
  expect(painted.get(MARKDOWN_FIND_HIGHLIGHT)?.length).toBe(2);
});

test("Escape clears the highlights and gives the document the keyboard back", () => {
  const find = page("<p>needle</p>");
  find.show("needle");
  expect(painted.has(MARKDOWN_FIND_ACTIVE_HIGHLIGHT)).toBe(true);
  find.hide();
  expect(find.getState().open).toBe(false);
  expect(painted.size).toBe(0);
  expect(document.activeElement?.getAttribute("contenteditable")).toBe("true");
});

test("Use Selection for Find searches the selected text", () => {
  const find = page("<p>pick this word and this word</p>");
  const text = document.querySelector("p")!.firstChild!;
  const range = document.createRange();
  range.setStart(text, 5);
  range.setEnd(text, 9);
  document.getSelection()!.removeAllRanges();
  document.getSelection()!.addRange(range);
  find.useSelection();
  expect(find.getState().query).toBe("this");
  expect(find.getState().matches.length).toBe(2);
});

test("source mode searches the text area and selects the active match", () => {
  const find = page("", "source", "# Title\nsome text\nmore text");
  find.show("text");
  expect(find.getState().matches.length).toBe(2);
  const textarea = document.querySelector<HTMLTextAreaElement>(".md-source")!;
  const selected = () => textarea.value.slice(textarea.selectionStart, textarea.selectionEnd);
  expect(selected()).toBe("text");
  expect(textarea.selectionStart).toBe("# Title\nsome ".length);
  find.next();
  expect(textarea.selectionStart).toBe("# Title\nsome text\nmore ".length);
});

test("the pill shows the count and steps with Enter", async () => {
  const find = page("<p>one two one</p>");
  const host = document.createElement("div");
  document.body.append(host);
  const strings = {
    language: "en",
    t: (key: string) => key,
    format: (key: string, ...args: string[]) => `${key}:${args.join("/")}`,
  };
  const root = createRoot(host);
  await act(async () => root.render(<MarkdownFindBar find={find} strings={strings as never} />));
  expect(host.querySelector("#md-find-bar")).toBeNull();
  await act(async () => find.show("one"));
  expect(host.querySelector("#md-find-bar")).not.toBeNull();
  expect(document.activeElement?.id).toBe("md-find-input");
  expect(host.querySelector("#md-find-count")?.textContent).toBe("find.count:1/2");
  const field = host.querySelector<HTMLInputElement>("#md-find-input")!;
  await act(async () => {
    field.dispatchEvent(new window.KeyboardEvent("keydown", { key: "Enter", bubbles: true }));
  });
  expect(host.querySelector("#md-find-count")?.textContent).toBe("find.count:2/2");
  await act(async () => root.unmount());
});

test("a match after İ in source mode is selected at the right characters", () => {
  const find = page("", "source", "İa needle\nİİ NEEDLE");
  find.show("needle");
  expect(find.getState().matches.length).toBe(2);
  const textarea = document.querySelector<HTMLTextAreaElement>(".md-source")!;
  const selected = () => textarea.value.slice(textarea.selectionStart, textarea.selectionEnd);
  expect(selected()).toBe("needle");
  find.next();
  expect(selected()).toBe("NEEDLE");
});
