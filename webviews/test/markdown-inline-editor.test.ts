import { afterEach, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { JSDOM } from "jsdom";

const asset = (name: string) =>
  readFileSync(new URL("../../Resources/markdown-viewer/" + name, import.meta.url), "utf8");
const assets: Record<string, string> = {
  markedJS: asset("marked.min.js"),
  highlightJS: asset("highlight.min.js"),
  viewerNavigationJS: asset("viewer-navigation.js"),
  localizedStringsJSON: "{}",
  githubMarkdownCSS: "",
  highlightLightCSS: "",
  highlightDarkCSS: "",
};
const html = asset("shell.html").replace(/\{\{(\w+)\}\}/g, (_, key: string) => assets[key] ?? "");
const documents: JSDOM[] = [];

afterEach(() => {
  documents.splice(0).forEach((dom) => dom.window.close());
});

function editor(markdown: string) {
  const dom = new JSDOM(html, { runScripts: "outside-only", url: "file:///tmp/demo.md" });
  documents.push(dom);
  const messages: Array<{ action?: string; markdown?: string }> = [];
  const frames: FrameRequestCallback[] = [];
  const window = dom.window;
  Object.assign(window.document, { elementFromPoint: () => null });
  Object.assign(window, {
    matchMedia: () => ({ matches: false, addEventListener() {} }),
    requestAnimationFrame: (callback: FrameRequestCallback) => frames.push(callback),
    scrollTo() {},
    webkit: { messageHandlers: { cmuxLib: { postMessage: (value: typeof messages[number]) => messages.push(value) } } },
  });
  for (const script of window.document.querySelectorAll("script")) window.eval(script.textContent ?? "");
  const api = window as unknown as {
    __cmuxRenderMarkdown(source: string): void;
    __cmuxSetMarkdownEditing(enabled: boolean): void;
    __cmuxFlushMarkdownEdits(): string;
  };
  api.__cmuxRenderMarkdown(markdown);
  api.__cmuxSetMarkdownEditing(true);
  const content = window.document.getElementById("content")!;
  return {
    api, content, window,
    edits: () => messages.filter((message) => message.action === "editMarkdown"),
    input() { content.dispatchEvent(new window.Event("input", { bubbles: true })); },
    frame() { frames.splice(0).forEach((callback) => callback(0)); },
  };
}

test("inline hard breaks remain line breaks when saved", () => {
  const page = editor("Before\n");
  page.content.innerHTML = "<p>First<br>Second</p>";
  page.input();
  page.frame();
  expect(page.edits().at(-1)?.markdown).toBe("First  \nSecond\n");
});

test("repeated editing state updates do not consume pending input", () => {
  const page = editor("Before\n");
  page.content.querySelector("p")!.textContent = "Latest edit";
  page.input();
  page.api.__cmuxSetMarkdownEditing(true);
  page.frame();
  expect(page.edits().at(-1)?.markdown).toBe("Latest edit\n");
});

test("typing into an empty document and browser div paragraphs saves all text", () => {
  const page = editor("");
  page.content.innerHTML = "First<div>Second <b>bold</b></div>";
  page.input();
  page.frame();
  expect(page.edits().at(-1)?.markdown).toBe("First\n\nSecond **bold**\n");
});

test("leaving editing flushes the pending input before the next frame", () => {
  const page = editor("Before\n");
  page.content.querySelector("p")!.textContent = "Latest edit";
  page.input();
  page.api.__cmuxSetMarkdownEditing(false);
  expect(page.edits().at(-1)?.markdown).toBe("Latest edit\n");
  page.frame();
  expect(page.edits()).toHaveLength(1);
});

test("explicit save flushes input once and preserves untouched source", () => {
  const page = editor("*Original*");
  expect(page.api.__cmuxFlushMarkdownEdits()).toBe("*Original*");
  expect(page.edits()).toHaveLength(0);
  page.content.querySelector("em")!.textContent = "Changed";
  page.input();
  expect(page.api.__cmuxFlushMarkdownEdits()).toBe("*Changed*\n");
  page.frame();
  expect(page.edits()).toHaveLength(1);
});

test("remote images keep their original URL after consent loads them", () => {
  const page = editor("![Example](https://example.com/image.png)\n");
  const img = page.content.querySelector("img")!;
  img.setAttribute("src", "cmux-remote-image://image?url=consented");
  page.content.appendChild(page.window.document.createElement("p")).textContent = "New";
  page.input();
  page.frame();
  expect(page.edits().at(-1)?.markdown).toBe("![Example](https://example.com/image.png)\n\nNew\n");
});
