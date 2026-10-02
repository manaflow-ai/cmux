// Markdown cases from real Codex replies that the renderer must draw the way the desktop
// app does. Ported from manaflow-ai/codex-atlas-clone (src/conversation/markdown.test.ts).
import { describe, expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { createElement } from "react";
import { Markdown, parseMarkdown } from "./Markdown";
import { normalizeMath } from "./mathDelimiters";
import specimen from "../../../../scripts/agent-pane/specimen.json";

const answerUpdate = specimen.steps.find((step) => "messageId" in step.update && step.update.messageId === "answer")!.update;
const specimenAnswer = "content" in answerUpdate && answerUpdate.content && !Array.isArray(answerUpdate.content) ? answerUpdate.content.text : "";
const html = (source: string) => renderToStaticMarkup(createElement(Markdown, null, source));

describe("math delimiters", () => {
  test("\\[ … \\] display blocks, also across lines, become $$ … $$", () => {
    expect(normalizeMath(["\\[", "10x + (9-x) = 9x + 9", "\\]"])).toEqual([
      "$$10x + (9-x) = 9x + 9$$",
    ]);
    expect(normalizeMath(["\\[ x = 3 \\]"])).toEqual(["$$x = 3$$"]);
  });

  test("\\( … \\) inline math becomes $ … $", () => {
    expect(normalizeMath(["Let the tens digit be \\(x\\). So \\(9-x\\)."])).toEqual([
      "Let the tens digit be $x$. So $9-x$.",
    ]);
  });

  test("code fences are left alone", () => {
    expect(normalizeMath(["```text", "\\(x\\)", "```"])).toEqual(["```text", "\\(x\\)", "```"]);
  });

  test("the specimen's puzzle typesets every step", () => {
    const blocks = parseMarkdown(specimenAnswer);
    expect(blocks.filter((b) => b.type === "math").length).toBeGreaterThanOrEqual(6);
  });
});

describe("lists and quotes", () => {
  const src = [
    "2. Second numbered item",
    "   - Supporting bullet",
    "",
    "- [x] Completed task",
    "- [ ] Remaining task",
    "",
    "> “A user interface is a conversation between intention and response.”",
    ">",
    "> — Design notebook",
  ].join("\n");

  test("a task list after a numbered list is its own top-level list", () => {
    const blocks = parseMarkdown(src);
    expect(blocks.map((b) => b.type)).toEqual(["list", "list", "blockquote"]);
    const html = renderToStaticMarkup(createElement(Markdown, null, src));
    // depth 0 + cv-tasks is what conversation.css indents like a nested list
    expect(html).toContain('class="cv-list cv-ul cv-tasks" data-depth="0"');
  });

  test("a blockquote keeps its two paragraphs (drawn without a gap by .cv-quote > .cv-p)", () => {
    const quote = parseMarkdown(src)[2]!;
    expect(quote.type === "blockquote" && quote.children.map((c) => c.type)).toEqual([
      "paragraph",
      "paragraph",
    ]);
  });
});

describe("the pane's earlier renderer gaps", () => {
  test("a list inside a blockquote draws as a list", () => {
    expect(html("> - one\n> - two")).toContain('<blockquote class="cv-quote"><ul class="cv-list cv-ul"');
  });

  test("items of a loose list stay separate items", () => {
    const [list] = parseMarkdown("- one\n\n- two\n\n- three");
    expect(list?.type === "list" && list.items.map((item) => item.text)).toEqual(["one", "two", "three"]);
  });

  test("task items draw checkboxes, not brackets", () => {
    const out = html("- [x] done\n- [ ] todo");
    expect(out).toContain("cv-checkbox is-checked");
    expect(out).not.toContain("[ ]");
    expect(out).not.toContain("[x]");
  });
});

describe("links", () => {
  test("a web link keeps its href; a script link draws as text", () => {
    expect(html("[site](https://example.com)")).toContain('href="https://example.com"');
    const unsafe = html("[run](javascript:alert(1))");
    expect(unsafe).not.toContain("<a");
    expect(unsafe).toContain("run");
  });
});

describe("the specimen", () => {
  test("renders headings, lists, a table, code and math", () => {
    const types = new Set(parseMarkdown(specimenAnswer).map((block) => block.type));
    for (const type of ["heading", "list", "table", "code", "blockquote", "hr", "math"]) expect(types.has(type as never)).toBe(true);
  });
});
