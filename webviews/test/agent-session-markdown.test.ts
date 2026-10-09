import { afterAll, describe, expect, test } from "bun:test";
import { createRequire } from "node:module";
import { join } from "node:path";
import { JSDOM } from "jsdom";
import { renderMarkdownFragment, renderPlainTextFragment } from "../src/agent-session/shared/markdown";
import { unsafeNodes } from "./markdown-viewer-shell.harness";

const require = createRequire(import.meta.url);
const marked = require(join(import.meta.dir, "../../Resources/markdown-viewer/marked.min.js"));
const dom = new JSDOM("<!doctype html><html><body><div id='root'></div></body></html>");

afterAll(() => {
  dom.window.close();
});

function render(markdown: string): HTMLElement {
  const root = dom.window.document.getElementById("root") as HTMLElement;
  root.replaceChildren(renderMarkdownFragment(markdown, dom.window.document, marked));
  return root;
}

describe("rendered transcript markdown contains no active content", () => {
  const payloads: Array<[string, string]> = [
    ["comment and noscript mutation", '<!--x--><noscript><p title="</noscript><img src=x onerror=alert(1)>">'],
    ["escaped backtick into raw HTML", '\\`<!--x--><noscript><p title="</noscript><img src=x onerror=alert(1)>">`'],
    ["raw-text elements", "\\`<noembed><p title='</noembed><img src=x onerror=alert(1)>'>` <xmp>x</xmp> <plaintext>"],
    ["SMIL animation rewriting a link", "\\`<svg><a><animate attributeName=href to=javascript:alert(1) /><text>x</text></a></svg>`"],
    ["SVG set element", "\\`<svg><a href=#><set attributeName=href to=javascript:alert(1) />x</a></svg>`"],
    ["fence close mismatch", "```\ncode\n```~\n<img src=x onerror=alert(1)><iframe srcdoc=x></iframe>"],
    ["fence info mismatch", "```js`x\n<img src=x onerror=alert(1)>\n```"],
    ["list-item fence ending early", "- a\n   ```js\n<img src=x onerror=alert(1)>"],
    ["javascript link", "[x](javascript:alert(1)) [y](JaVaScRiPt:alert(1)) <javascript:alert(1)>"],
    ["data and vbscript links", "[x](data:text/html,<script>alert(1)</script>) [y](vbscript:msgbox)"],
    ["inert containers", "\\`<template><img src=x onerror=alert(1)></template><object data=x></object><embed src=x>`"],
  ];

  for (const [name, payload] of payloads) {
    test(name, () => {
      const root = render(payload);
      expect(unsafeNodes(root)).toEqual([]);
      expect(root.querySelector("img, svg, iframe, object, embed, template, noscript, a[href^='javascript']")).toBeNull();
    });
  }

  test("ordinary markdown still renders", () => {
    const root = render("# Title\n\n**bold** `<b>code</b>` [docs](https://example.com)\n\n```ts\nconst a = 1 < 2;\n```");
    expect(root.querySelector("h1")?.textContent).toBe("Title");
    expect(root.querySelector("strong")?.textContent).toBe("bold");
    expect(root.querySelector("p code")?.textContent).toBe("<b>code</b>");
    expect(root.querySelector("a")?.getAttribute("href")).toBe("https://example.com");
    expect(root.querySelector("a")?.getAttribute("rel")).toBe("noopener noreferrer");
    expect(root.querySelector("pre code")?.textContent).toBe("const a = 1 < 2;\n");
  });

  test("raw HTML the parser still tokenizes renders as text", () => {
    const root = render("- a\n   ```js\n<b>bold</b>");
    expect(root.querySelector("b")).toBeNull();
    expect(root.textContent).toContain("<b>bold</b>");
  });

  test("images do not fetch", () => {
    const root = render("![x](https://example.com/a.png)");
    expect(root.querySelector("img")).toBeNull();
  });
});

test("plain text fragment preserves line breaks safely", () => {
  const root = dom.window.document.getElementById("root") as HTMLElement;
  root.replaceChildren(renderPlainTextFragment("hello\n<script>x</script>", dom.window.document));
  expect(root.innerHTML).toBe("hello<br>&lt;script&gt;x&lt;/script&gt;");
});
