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
  const messages: Array<{ action?: string; href?: string; markdown?: string }> = [];
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
    __cmuxFormatMarkdown(action: string): void;
  };
  api.__cmuxRenderMarkdown(markdown);
  api.__cmuxSetMarkdownEditing(true);
  const content = window.document.getElementById("content")!;
  return {
    api, content, window, messages,
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

test("inline code keeps the smallest valid Markdown fence", () => {
  const page = editor("`Original`\n");
  page.content.querySelector("p")!.textContent = "inline code";
  page.input();
  page.frame();
  expect(page.edits().at(-1)?.markdown).toBe("inline code\n");
  page.content.querySelector("p")!.innerHTML = "<code>value</code>";
  page.input();
  page.frame();
  expect(page.edits().at(-1)?.markdown).toBe("`value`\n");
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

test("table commands add rows and columns without leaving the table", () => {
  const page = editor("| A | B |\n| --- | --- |\n| one | two |\n");
  const cell = page.content.querySelector("tbody td")!;
  const range = page.window.document.createRange();
  range.selectNodeContents(cell);
  range.collapse(false);
  const selection = page.window.getSelection()!;
  selection.removeAllRanges();
  selection.addRange(range);

  page.api.__cmuxFormatMarkdown("tableAddRowAfter");
  page.api.__cmuxFormatMarkdown("tableAddColumnBefore");
  page.frame();

  expect(page.content.querySelectorAll("tr")).toHaveLength(3);
  expect(page.content.querySelector("thead tr")?.children).toHaveLength(3);
  expect(page.edits().at(-1)?.markdown).toContain("|  | A | B |");
  expect(page.edits().at(-1)?.markdown).toContain("|  |  |  |\n");
});

test("adding a row from the header keeps the Markdown header intact", () => {
  const page = editor("| A | B |\n| --- | --- |\n| one | two |\n");
  const header = page.content.querySelector("thead th")!;
  const range = page.window.document.createRange();
  range.selectNodeContents(header);
  range.collapse(false);
  const selection = page.window.getSelection()!;
  selection.removeAllRanges();
  selection.addRange(range);
  page.api.__cmuxFormatMarkdown("tableAddRowAfter");
  page.frame();
  expect(page.content.querySelector("thead")?.querySelectorAll("tr")).toHaveLength(1);
  expect(page.content.querySelectorAll("tbody tr")).toHaveLength(2);
});

test("Tab moves to the next table cell and appends a row at the end", () => {
  const page = editor("| A | B |\n| --- | --- |\n| one | two |\n");
  const lastCell = page.content.querySelector("tbody tr:last-child td:last-child")!;
  const range = page.window.document.createRange();
  range.selectNodeContents(lastCell);
  range.collapse(false);
  const selection = page.window.getSelection()!;
  selection.removeAllRanges();
  selection.addRange(range);
  lastCell.dispatchEvent(new page.window.KeyboardEvent("keydown", { key: "Tab", bubbles: true, cancelable: true }));
  page.frame();
  expect(page.content.querySelectorAll("tbody tr")).toHaveLength(2);
});

test("link menu opens links in cmux and edits the URL and label", () => {
  const page = editor("[Original](https://example.com/old)\n");
  const anchor = page.content.querySelector("a")!;
  anchor.dispatchEvent(new page.window.MouseEvent("click", { bubbles: true, cancelable: true }));
  const menu = page.window.document.querySelector(".cmux-link-menu")!;
  expect(menu.textContent).toContain("Open in cmux");
  (menu.querySelector("button") as HTMLButtonElement).click();
  expect(page.edits()).toHaveLength(0);
  expect(page.messages.at(-1)).toEqual({ action: "openMarkdownLink", href: "https://example.com/old" });

  anchor.dispatchEvent(new page.window.MouseEvent("click", { bubbles: true, cancelable: true }));
  const editMenu = page.window.document.querySelector(".cmux-link-menu")!;
  const buttons = editMenu.querySelectorAll("button");
  buttons[3].click();
  const inputs = editMenu.querySelectorAll("input");
  (inputs[0] as HTMLInputElement).value = "https://example.com/new";
  (inputs[1] as HTMLInputElement).value = "Changed";
  (editMenu.querySelector("button") as HTMLButtonElement).click();
  page.frame();
  expect(page.edits().at(-1)?.markdown).toBe("[Changed](https://example.com/new)\n");
});
