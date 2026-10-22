// An agent's inline Markdown in a question draws as marks, never as backticks and asterisks, and
// nothing in it becomes a control inside an option row (a link draws as its label).
import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { hasMarks, inlineText } from "./inlineText";

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
