// l10n-allow-file: fixture prompts, not shipped UI.
// A sent prompt goes through the transcript's Markdown only when it is written in Markdown
// (promptMarkdown.ts): block syntax at a line start, or paired inline syntax. One stray `_`, `$`,
// `#`, `<`, `|` or a bare address is ordinary text and stays literal, line breaks and all, with
// the address a link (PromptText.tsx PromptTyped).
import { describe, expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { isPromptMarkdown } from "./promptMarkdown";
import { PromptTyped } from "./PromptText";

const draw = (text: string) => renderToStaticMarkup(<PromptTyped text={text} show={(shown) => shown} />);
const literal = (html: string) => html.startsWith('<span class="cv-user__typed">');

const LITERAL: [string, string][] = [
  ["snake_case", "rename user_id to account_id in load_user_profile"],
  ["dunder", "why does __init__ run twice"],
  ["price", "it costs $5, or $12.50 with tax"],
  ["two prices", "between $5 and $10"],
  ["issue number", "see #123 and #45 for context"],
  ["less than", "check that a<b and c > d"],
  ["pipe", "run it with a | b in the shell"],
  ["lone asterisk", "2 * 3 = 6, and a*b"],
  ["unpaired bold", "a ** b"],
  ["lone backtick", "the ` key is broken"],
  ["lone bracket", "array[0] is empty"],
  ["tilde path", "open ~/notes and C:\\tmp"],
  ["lone url", "https://example.com/a_b?x=1#frag"],
  ["url in prose", "look at https://example.com/docs_v2 please"],
  ["hash without space", "#123\n#tag"],
  ["minus number", "-5 degrees outside"],
  ["decimal", "1.5 is the version"],
  ["c sharp", "C# and F# both"],
  ["indented hash", "  # not a heading here"],
  ["multiline", "first line\nsecond line\n\nafter a blank"],
  ["rule", "---"],
  ["star inside bold", "**a*b**"],
  ["titled link", '[docs](https://example.com "title")'],
];

const MARKDOWN: [string, string, string][] = [
  ["dash list", "- one\n- two", "<li>"],
  ["star list", "* one\n* two", "<li>"],
  ["ordered list", "1. first\n2. second", "<ol"],
  // Markdown.tsx's LIST_RE takes a number of any length (`\d+`), so the gate does too.
  ["long ordered marker", "1234567890. first\n1234567891. second", "<ol"],
  ["long ordered paren marker", "20261031001) first", "<ol"],
  ["list after prose", "do these:\n- one\n- two", "<li>"],
  ["indented list", "    - nested item", "<li>"],
  ["fence", "```ts\nconst a_b = 1;\n```", "<pre"],
  ["heading", "# Title\nbody", "<h"],
  ["sub heading", "### Sub head", "<h"],
  ["quote", "> quoted line\nreply", "cv-quote"],
  ["table", "| a | b |\n| --- | --- |\n| 1 | 2 |", "<table"],
  ["bare table", "a | b\n---|---\n1 | 2", "<table"],
  ["one column table", "| a |\n|---|\n| 1 |", "<table"],
  // Markdown.tsx reads `\r\n` and a lone `\r` as line breaks, so the gate does too.
  ["crlf table", "| a | b |\r\n| --- | --- |\r\n| 1 | 2 |", "<table"],
  ["cr table", "| a | b |\r| --- | --- |\r| 1 | 2 |", "<table"],
  ["cr list", "do these:\r- one\r- two", "<li>"],
  ["code span", "run `bun test` now", "<code"],
  ["bold", "this is **really** it", "<strong>really</strong>"],
  ["link", "see [the docs](https://example.com/docs)", 'href="https://example.com/docs"'],
];

describe("sent prompt Markdown gate", () => {
  for (const [name, text] of LITERAL)
    test(`${name} stays literal`, () => {
      expect(isPromptMarkdown(text)).toBe(false);
      const html = draw(text);
      expect(literal(html)).toBe(true);
      expect(html).not.toContain("cv-user__markdown");
    });

  for (const [name, text, mark] of MARKDOWN)
    test(`${name} renders`, () => {
      expect(isPromptMarkdown(text)).toBe(true);
      const html = draw(text);
      expect(html).toContain("cv-user__markdown");
      expect(html).toContain(mark);
    });

  test("literal text keeps every character and its line breaks", () => {
    const text = "rename user_id\ncosts $5 #123 a<b\n\nend";
    const span = draw(text);
    // The bubble is `white-space: pre-wrap`; the span holds the newlines as typed, no <br> or <p>.
    expect(span).not.toContain("<p");
    const textOnly = span
      .replace(/<[^>]+>/g, "")
      .replaceAll("&lt;", "<")
      .replaceAll("&amp;", "&");
    expect(textOnly).toBe(text);
  });

  test("a bare address on the literal path is a link", () => {
    const html = draw("look at https://example.com/docs_v2 please");
    expect(literal(html)).toBe(true);
    expect(html).toContain('href="https://example.com/docs_v2"');
    expect(html.replace(/<[^>]+>/g, "")).toBe("look at https://example.com/docs_v2 please");
  });

  // The gate runs while drawing; a 64k paste of one character must not stall the pane.
  test("a long run of one marker is tested in linear time", () => {
    const n = 65_536;
    const inputs = [
      "a|".repeat(n / 2),
      "[".repeat(n),
      "`".repeat(n),
      "**a ".repeat(n / 4),
      `[a](${"b".repeat(n)}`,
      `${" ".repeat(n)}|x`,
      `x | y\n|-- ${" ".repeat(n)}x`,
      `${"- ".repeat(n / 2)}`,
      "1".repeat(n),
      `${"1".repeat(n)}.`,
    ];
    const started = performance.now();
    for (const input of inputs) isPromptMarkdown(input);
    expect(performance.now() - started).toBeLessThan(250);
  });

  test("a lone address is one link", () => {
    const html = draw("https://example.com/a_b?x=1");
    expect(literal(html)).toBe(true);
    expect(html.match(/<a /g)?.length).toBe(1);
  });
});
