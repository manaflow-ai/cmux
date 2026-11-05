// l10n-allow-file: test fixtures.
// Rich text on the clipboard (richClipboard.ts): a reply's Markdown as HTML for other apps, and HTML
// from other apps (and the transcript's own selection copy) as Markdown for the composer.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { htmlHasBlocks, htmlMarkdown, looksLikeMarkdown, markdownHtml } from "./richClipboard";

const scope = globalThis as Record<string, unknown>;
const KEYS = ["document", "Node"];
const saved = new Map<string, unknown>();

beforeAll(() => {
  const dom = new JSDOM("<!doctype html><html><body></body></html>");
  for (const key of KEYS) {
    saved.set(key, scope[key]);
    scope[key] = (dom.window as unknown as Record<string, unknown>)[key];
  }
});
afterAll(() => {
  for (const key of KEYS) scope[key] = saved.get(key);
});

const REPLY = [
  "## Plan",
  "",
  "Ship it **today**, see [the PR](https://example.com/pr).",
  "",
  "- first",
  "- second",
  "  - nested",
  "",
  "1. one",
  "2. two",
  "",
  "```ts",
  "const a = 1;",
  "```",
].join("\n");

test("a reply's Markdown copies as HTML with its headings, lists, emphasis, links and code", () => {
  const html = markdownHtml(REPLY);
  expect(html).toContain("<h2>Plan</h2>");
  expect(html).toContain("<strong>today</strong>");
  expect(html).toContain('<a href="https://example.com/pr">the PR</a>');
  expect(html).toMatch(/<ul>\s*<li>first<\/li>/);
  expect(html).toContain("<ol>");
  expect(html).toContain('<code class="language-ts">const a = 1;');
});

test("raw HTML in a reply copies as text, never markup", () => {
  expect(markdownHtml("<script>alert(1)</script>\n\nok")).not.toContain("<script>");
});

test("HTML reads back as the same Markdown", () => {
  expect(htmlMarkdown(markdownHtml(REPLY))).toBe(REPLY);
});

test("Notes and Docs HTML: nested lists beside items, Docs' bold spans and its normal-weight wrapper", () => {
  const notes = "<ul><li>a</li><ul><li>b</li></ul><li>c</li></ul>";
  expect(htmlMarkdown(notes)).toBe("- a\n   - b\n- c");
  const docs =
    '<b style="font-weight:normal" id="docs-internal-guid-1"><p><span style="font-weight:700">Bold</span> plain</p><ol><li><p>x</p></li></ol></b>';
  expect(htmlMarkdown(docs)).toBe("**Bold** plain\n\n1. x");
});

test("escape keeps text's own Markdown characters text for the composer's parser", () => {
  expect(htmlMarkdown("<ul><li>a_b * c</li></ul>", { escape: true })).toBe("- a\\_b \\* c");
  expect(htmlMarkdown("<ul><li>a_b * c</li></ul>")).toBe("- a_b * c");
});

test("what reads as Markdown on paste: lists and fences, not a lone heading or plain lines", () => {
  expect(looksLikeMarkdown("Intro\n- one\n- two")).toBe(true);
  expect(looksLikeMarkdown("1. one\n2. two")).toBe(true);
  expect(looksLikeMarkdown("```\ncode\n```")).toBe(true);
  expect(looksLikeMarkdown("# a shell comment\necho hi")).toBe(false);
  expect(looksLikeMarkdown("First paragraph\n\nSecond, line one\nSecond, line two")).toBe(false);
  expect(looksLikeMarkdown("a -b flag")).toBe(false);
  expect(htmlHasBlocks("<p>one</p><p><br></p><p>two</p>")).toBe(false);
  expect(htmlHasBlocks("<meta charset='utf-8'><ul><li>x</li></ul>")).toBe(true);
});
