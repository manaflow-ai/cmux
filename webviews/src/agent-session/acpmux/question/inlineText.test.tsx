// An agent's inline Markdown in a question draws as marks, never as backticks and asterisks, and
// nothing in it becomes a control inside an option row (a link draws as its label).
import { expect, test } from "bun:test";
import { isValidElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { hasMarks, inlineText } from "./inlineText";
import type { AgentQuestion } from "./model";
import { QuestionCard } from "./QuestionCard";

const html = (text: string) => renderToStaticMarkup(<>{inlineText(text)}</>);

test("plain text comes back as the same string", () => {
  expect(inlineText("Which layout should the settings page use?")).toBe("Which layout should the settings page use?");
  expect(hasMarks("2 * 3 = 6, snake_case_name, $5")).toBe(false);
});

test("code, bold, italic and struck text draw as marks", () => {
  expect(html("Use `formatDate` for **dates**")).toBe(
    'Use <code class="acpmux-question-code">formatDate</code> for <strong>dates</strong>',
  );
  expect(html("the *standard* or _plain_ ~~old~~ way")).toBe(
    "the <em>standard</em> or <em>plain</em> <del>old</del> way",
  );
  expect(html("**bold `code` inside**")).toBe(
    '<strong>bold <code class="acpmux-question-code">code</code> inside</strong>',
  );
});

test("a link draws as its label, never an anchor", () => {
  expect(html("See [the docs](https://example.com) and [`x`](https://x.dev)")).toBe(
    'See the docs and <code class="acpmux-question-code">x</code>',
  );
});

test("a backslash escape draws its character", () => {
  expect(html("a \\*literal\\* star")).toBe("a *literal* star");
});

test("markup in the text stays text", () => {
  expect(html("**<img src=x onerror=alert(1)>**")).toBe("<strong>&lt;img src=x onerror=alert(1)&gt;</strong>");
});

test("many marks around a link keep distinct keys", () => {
  const text = "`a` [`b`](u) " + Array.from({ length: 12 }, (_, i) => `\`c${i}\``).join(" ");
  const keys: string[] = [];
  const walk = (node: unknown) => {
    if (Array.isArray(node)) node.forEach(walk);
    else if (isValidElement<{ children?: unknown }>(node)) {
      keys.push(String(node.key));
      walk(node.props.children);
    }
  };
  walk(inlineText(text));
  expect(new Set(keys).size).toBe(keys.length);
});

test("the question card draws marks in the prompt, the labels and the descriptions", () => {
  const question: AgentQuestion = {
    id: "perm_marks",
    source: {
      harness: "claude",
      session: "s",
      permission: "perm_marks",
      agentName: "Claude Code",
      answerOption: "allow_once",
      rejectOption: "reject_once",
    },
    items: [
      {
        id: "q0",
        header: "Library",
        prompt: "Which library should `formatDate` use?",
        options: [
          { id: "`Temporal`", label: "`Temporal`", detail: "The **standard** API." },
          { id: "Intl", label: "Intl", detail: "No dependency." },
        ],
        multiSelect: false,
        allowsOther: false,
      },
    ],
    state: { kind: "pending" },
  };
  const card = renderToStaticMarkup(<QuestionCard question={question} onReply={() => undefined} />);
  expect(card).toContain('<code class="acpmux-question-code">formatDate</code>');
  expect(card).toContain('<code class="acpmux-question-code">Temporal</code>');
  expect(card).toContain("<strong>standard</strong>");
  expect(card).not.toContain("`");
  expect(card).not.toContain("**");
});
