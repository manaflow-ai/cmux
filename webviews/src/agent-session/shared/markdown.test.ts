import { expect, test } from "bun:test";
import { escapeMarkdownRawHTML, isSafeURL, renderPlainTextHTML, sanitizedMarkdownURLAttribute } from "./markdown";

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
