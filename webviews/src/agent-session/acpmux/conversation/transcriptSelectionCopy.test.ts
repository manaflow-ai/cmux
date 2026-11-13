// l10n-allow-file: clipboard regression fixtures.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { settleReact } from "../../../../test/support/domTeardown";
import { JSDOM } from "jsdom";
import { htmlMarkdown } from "../richClipboard";
import { menuPartRef } from "./menuParts";
import { installSelectionCopy, selectionHtml } from "./selectionCopy";

const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();
let doc: Document;

beforeAll(() => {
  const dom = new JSDOM(`<!doctype html><body><main>
    <article><div class="cv-md"><h2 id="first">Start here</h2><p>One</p></div><button class="cv-iconbtn">Copy message</button></article>
    <article><div class="cv-user__text"><div class="cv-md"><ul><li>Keep lists</li><li>And <strong>bold</strong></li></ul></div></div><time>10:30 AM</time></article>
    <article><div class="cv-md"><div class="cv-codeblock" id="card"><header>Python <button>Copy code</button></header><div id="highlight"></div></div><p id="last">Finish here</p></div></article>
    </main><textarea>draft</textarea></body>`);
  for (const key of ["document", "Node", "HTMLAnchorElement"]) {
    saved.set(key, scope[key]);
    scope[key] = (dom.window as unknown as Record<string, unknown>)[key];
  }
  doc = dom.window.document;
  doc.getElementById("highlight")!.attachShadow({ mode: "open" }).innerHTML = "<pre>highlighted lines</pre>";
  menuPartRef({ code: "if ready:\n    run()\n", codeLanguage: "python" })(doc.getElementById("card"));
});

afterAll(async () => {
  await settleReact();
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
});

test("three messages copy headings, lists and shadow-rendered code without transcript controls", () => {
  const range = doc.createRange();
  range.setStart(doc.getElementById("first")!.firstChild!, 0);
  range.setEnd(doc.getElementById("last")!.firstChild!, 11);
  const html = selectionHtml(range);
  expect(html).not.toBeNull();
  expect(htmlMarkdown(html!)).toBe(
    "## Start here\n\nOne\n\n- Keep lists\n- And **bold**\n\n```python\nif ready:\n    run()\n```\n\nFinish here",
  );
  expect(html).not.toMatch(/Copy message|Copy code|10:30|highlighted lines|class="cv-|style=/);
});

test("partial first and last messages copy only their selected words", () => {
  const range = doc.createRange();
  range.setStart(doc.getElementById("first")!.firstChild!, 6);
  range.setEnd(doc.getElementById("last")!.firstChild!, 6);
  const markdown = htmlMarkdown(selectionHtml(range)!);
  expect(markdown).toStartWith("## here\n\n");
  expect(markdown).toEndWith("\n\nFinish");
});

test("a selection extending outside message content stays the page's copy", () => {
  const range = doc.createRange();
  range.setStart(doc.getElementById("first")!.firstChild!, 0);
  range.setEndAfter(doc.querySelector("textarea")!);
  expect(selectionHtml(range)).toBeNull();
});

test("selection inside highlighted code does not expand to unselected code", () => {
  const range = doc.createRange();
  range.setStart(doc.getElementById("card")!, 1);
  range.setEnd(doc.getElementById("last")!.firstChild!, 6);
  expect(selectionHtml(range)).toBeNull();
});

test("the copy event writes Markdown and clean HTML and preserves the selection", () => {
  installSelectionCopy();
  const selection = doc.getSelection()!;
  const range = doc.createRange();
  range.setStart(doc.getElementById("first")!.firstChild!, 0);
  range.setEnd(doc.getElementById("last")!.firstChild!, 11);
  selection.removeAllRanges();
  selection.addRange(range);
  const before = selection.toString();
  const data = new Map<string, string>();
  const event = new doc.defaultView!.Event("copy", { bubbles: true, cancelable: true });
  Object.defineProperty(event, "clipboardData", {
    value: { setData: (type: string, value: string) => data.set(type, value) },
  });
  doc.dispatchEvent(event);
  expect(event.defaultPrevented).toBe(true);
  expect(data.get("text/plain")).toContain("```python\nif ready:\n    run()\n```");
  expect(data.get("text/html")).toContain("<h2>Start here</h2>");
  expect(selection.toString()).toBe(before);
});

test("a plain code card uses its source once, including during highlight handoff", () => {
  const card = doc.getElementById("card")!;
  const shadow = doc.getElementById("highlight")!;
  const handoff = doc.createElement("div");
  handoff.className = "cv-code-handoff is-fading";
  card.before(handoff);
  handoff.append(card);
  const plain = card.cloneNode(true) as HTMLElement;
  plain.querySelector("#highlight")!.replaceWith(doc.createElement("pre"));
  menuPartRef({ code: "if ready:\n    run()\n", codeLanguage: "python" })(plain);
  handoff.prepend(plain);
  try {
    const range = doc.createRange();
    range.setStart(doc.getElementById("first")!.firstChild!, 0);
    range.setEnd(doc.getElementById("last")!.firstChild!, 11);
    const markdown = htmlMarkdown(selectionHtml(range)!);
    expect(markdown.match(/if ready:/g)).toHaveLength(1);
    expect(markdown).toContain("```python\nif ready:\n    run()\n```");
  } finally {
    handoff.replaceWith(card);
  }
  expect(shadow.shadowRoot).not.toBeNull();
});

function fixtureCopy(middle: string): string | null {
  const root = doc.createElement("section");
  root.innerHTML = `<div class="cv-md"><p id="begin">First</p></div>${middle}<div class="cv-md"><p id="end">Last</p></div>`;
  doc.body.append(root);
  try {
    const range = doc.createRange();
    range.setStart(root.querySelector("#begin")!.firstChild!, 0);
    range.setEnd(root.querySelector("#end")!.firstChild!, 4);
    return selectionHtml(range);
  } finally {
    root.remove();
  }
}

test("plain prompts preserve line breaks and indentation in both clipboard types", () => {
  const html = fixtureCopy('<div class="cv-user__text">First line\n    indented line\n\nLast line</div>')!;
  expect(htmlMarkdown(html)).toBe("First\n\nFirst line\n    indented line\n\nLast line\n\nLast");
  expect(html).toContain('style="white-space: pre-wrap;"');
});

test.each([
  '<div class="cv-tools"><button class="cv-tool">Run command</button><pre>result</pre></div>',
  '<div class="selectable">Shell output</div>',
  '<div data-path="file.ts">file.ts</div>',
  '<div class="cv-user__images"><img src="https://example.com/image.png"></div>',
  '<div class="cv-user__text"><img src="https://example.com/image.png"></div>',
  '<div class="new-row">Unrecognized selected content</div>',
])("unsupported selected content keeps browser copy: %s", (middle) => {
  expect(fixtureCopy(middle)).toBeNull();
});

test("unrendered display math remains TeX", () => {
  const html = fixtureCopy('<div class="cv-md"><pre class="cv-math-display cv-math-source">$$\nx^2\n$$</pre></div>')!;
  expect(htmlMarkdown(html)).toBe("First\n\n$$\nx^2\n$$\n\nLast");
});
