import { expect, test } from "bun:test";
import {
  escapeMarkdownRawHTML,
  highlightCodeHTML,
  highlightLanguageFromCodeClassName,
  isSafeHighlightHTML,
  isSafeURL,
  renderPlainTextHTML,
  sanitizedMarkdownURLAttribute,
} from "./markdown";

test("markdown raw HTML is escaped before parsing", () => {
  expect(escapeMarkdownRawHTML("<script>alert(1)</script> & text")).toBe(
    "&lt;script>alert(1)&lt;/script> &amp; text",
  );
});

test("markdown raw HTML escaping preserves code spans and fenced code", () => {
  expect(escapeMarkdownRawHTML("`<div>&</div>`\n```tsx\n<div>&</div>\n```\n<section>x</section>")).toBe(
    "`<div>&</div>`\n```tsx\n<div>&</div>\n```\n&lt;section>x&lt;/section>",
  );
});

test("plain text fallback preserves line breaks safely", () => {
  expect(renderPlainTextHTML("hello\n<script>x</script>")).toBe("hello<br>&lt;script&gt;x&lt;/script&gt;");
});

test("markdown code highlighting accepts marked language classes and aliases", () => {
  expect(highlightLanguageFromCodeClassName("language-ts")).toBe("typescript");
  expect(highlightLanguageFromCodeClassName("hljs lang-sh")).toBe("bash");
  expect(highlightLanguageFromCodeClassName("language-c++")).toBe("cpp");
  expect(highlightLanguageFromCodeClassName("plain-code")).toBeNull();
});

test("markdown code highlighting colors known languages safely", () => {
  const highlighted = highlightCodeHTML('const answer: number = 42;\nconst tag = "<script>";', "tsx");

  expect(highlighted).toContain('class="hljs-keyword"');
  expect(highlighted).toContain('class="hljs-number"');
  expect(highlighted).toContain("&lt;script&gt;");
  expect(highlighted).not.toContain("<script>");
});

test("markdown code highlighting leaves unknown languages plain", () => {
  expect(highlightCodeHTML("graph TD;", "mermaid")).toBeNull();
});

test("markdown code highlighting only allows span class markup", () => {
  expect(isSafeHighlightHTML('<span class="hljs-keyword">const</span>')).toBe(true);
  expect(isSafeHighlightHTML('<span class="hljs-title function_">main</span>')).toBe(true);
  expect(isSafeHighlightHTML('<span class="hljs-keyword" onclick="alert(1)">const</span>')).toBe(false);
  expect(isSafeHighlightHTML('<a class="hljs-link" href="https://example.com">link</a>')).toBe(false);
});

test("markdown URL sanitizer allows only external safe schemes and fragments", () => {
  expect(isSafeURL("#details")).toBe(true);
  expect(isSafeURL("https://example.com/docs")).toBe(true);
  expect(isSafeURL("http://example.com/docs")).toBe(true);
  expect(isSafeURL("mailto:support@example.com")).toBe(true);

  expect(isSafeURL("/etc/passwd")).toBe(false);
  expect(isSafeURL("relative.md")).toBe(false);
  expect(isSafeURL("file:///etc/passwd")).toBe(false);
  expect(isSafeURL("javascript:alert(1)")).toBe(false);
});

test("markdown sanitizer blocks passive media fetch URLs", () => {
  expect(sanitizedMarkdownURLAttribute("img", "src", "https://example.com/x.png")).toBeNull();
  expect(sanitizedMarkdownURLAttribute("source", "srcset", "https://example.com/x.png 1x")).toBeNull();
  expect(sanitizedMarkdownURLAttribute("video", "poster", "https://example.com/x.png")).toBeNull();

  expect(sanitizedMarkdownURLAttribute("a", "href", "https://example.com/docs")).toBe("https://example.com/docs");
  expect(sanitizedMarkdownURLAttribute("a", "href", "javascript:alert(1)")).toBeNull();
  expect(sanitizedMarkdownURLAttribute("div", "href", "https://example.com/docs")).toBeNull();
  expect(sanitizedMarkdownURLAttribute("img", "alt", "diagram")).toBeUndefined();
});
