// l10n-allow-file: fixture prompts, not shipped UI.
// A prompt of megabytes (a pasted log, a base64 blob) never freezes the chat that holds it (Leo,
// 2026-10-31: "this is completely hardlocked bc of message size"). Past HUGE_PROMPT_CHARS it draws as
// one literal text node (no Markdown, no link scan, no <wbr> per separator), collapsed it draws only
// its head, and the row estimate is its collapsed lines without lexing or measuring the text.
import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { PromptText, PromptTyped } from "./PromptText";
import {
  COLLAPSED_PROMPT_LINES,
  HUGE_PROMPT_CHARS,
  HUGE_PROMPT_HEAD_CHARS,
  PROMPT_MORE_HEIGHT,
  isHugePrompt,
  promptHead,
} from "./promptCollapse";
import { layoutConversation } from "../model";
import { currentChatMetrics } from "../chatDisplay";

const same = (text: string) => text;
// Base64-like: no spaces, a `/` every 64 characters, so softBreaks would put a <wbr> after each.
const blob = (chars: number) => "QUJD/".concat("A".repeat(59)).repeat(Math.ceil(chars / 64)).slice(0, chars);
// Markdown-shaped, so a small one would go through the Markdown renderer.
const markdown = (chars: number) => `# Log\n- item **bold** \`code\`\n${"x".repeat(chars)}`;

test("a huge typed part draws as one literal text node, with no break points or Markdown", () => {
  const text = markdown(HUGE_PROMPT_CHARS);
  const html = renderToStaticMarkup(<PromptTyped text={text} show={same} />);
  expect(html.startsWith('<span class="cv-user__typed">')).toBe(true);
  expect(html).not.toContain("<h");
  expect(html).not.toContain("<li");
  expect(html).not.toContain("<wbr");
  // A small one still renders its Markdown.
  expect(renderToStaticMarkup(<PromptTyped text={markdown(10)} show={same} />)).toContain("<li");
});

test("a huge sent prompt opens collapsed on its head only", () => {
  const text = blob(5 * 1024 * 1024);
  const html = renderToStaticMarkup(<PromptText rowId="huge" text={text} show={same} />);
  expect(html).toContain("is-clamped");
  expect(html).not.toContain("<wbr");
  expect(html.length).toBeLessThan(HUGE_PROMPT_HEAD_CHARS + 1_000);
  // A prompt under the threshold keeps its whole text in the clamp, as before.
  const small = blob(HUGE_PROMPT_CHARS - 1);
  expect(renderToStaticMarkup(<PromptText rowId="small" text={small} show={same} />).length).toBeGreaterThan(
    HUGE_PROMPT_CHARS - 1,
  );
});

test("a huge prompt's head never ends inside a surrogate pair", () => {
  const text = "a".repeat(9) + "😀" + "b".repeat(10);
  expect(promptHead(text, 10)).toBe("a".repeat(9));
  expect(promptHead(text, 11)).toBe("a".repeat(9) + "😀");
  expect(promptHead("short", 10)).toBe("short");
  expect(isHugePrompt("x".repeat(HUGE_PROMPT_CHARS))).toBe(false);
  expect(isHugePrompt("x".repeat(HUGE_PROMPT_CHARS + 1))).toBe(true);
});

test("a huge prompt's row is estimated as its collapsed lines, quickly", () => {
  const { lineHeight } = currentChatMetrics();
  const row = (id: string, text: string) => ({ id, version: 1, at: 0, kind: "user", text });
  const started = performance.now();
  const [huge] = [...layoutConversation([row("h", markdown(20 * 1024 * 1024))] as never, 720).heights];
  const elapsed = performance.now() - started;
  const [long] = [...layoutConversation([row("l", "A line that wraps.\n".repeat(200))] as never, 720).heights];
  // The same collapsed height as any long prompt: ten lines and Show more.
  expect(huge).toBe(long);
  expect(huge!).toBeGreaterThanOrEqual(COLLAPSED_PROMPT_LINES * lineHeight + PROMPT_MORE_HEIGHT);
  expect(elapsed).toBeLessThan(500);
});
