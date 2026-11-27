import { describe, expect, test } from "bun:test";
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

describe("escaper follows the bundled parser's backtick grammar", () => {
  test("a backslash-escaped backtick does not open a code span", () => {
    expect(escapeMarkdownRawHTML("\\`<img src=x onerror=alert(1)>`")).toBe("\\`&lt;img src=x onerror=alert(1)>`");
  });

  test("a code span closes only on a backtick run of the same length", () => {
    expect(escapeMarkdownRawHTML("``a```<b>`")).toBe("``a```&lt;b>`");
    expect(escapeMarkdownRawHTML("`` <b>x</b> ``")).toBe("`` <b>x</b> ``");
  });

  test("a backtick fence info string cannot contain a backtick", () => {
    expect(escapeMarkdownRawHTML("```js`x\n<img src=x>\n```")).toBe("```js`x\n&lt;img src=x>\n```");
  });

  test("a fence closes on the opening marker followed by fence characters", () => {
    expect(escapeMarkdownRawHTML("```\ncode\n```~\n<img src=x>")).toBe("```\ncode\n```~\n&lt;img src=x>");
    expect(escapeMarkdownRawHTML("~~~\ncode\n~~~\t\n<b>x</b>")).toBe("~~~\ncode\n~~~\t\n<b>x</b>");
  });
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
  expect(isSafeURL("java\tscript:alert(1)")).toBe(false);
  expect(isSafeURL("data:text/html,x")).toBe(false);
  expect(isSafeURL("vbscript:x")).toBe(false);
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
