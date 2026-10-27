// l10n-allow-file: Markdown parser regression fixtures.
import { expect, test } from "bun:test";
import { isValidElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { Markdown, parseMarkdown, renderInline } from "./Markdown";
import { MathInline } from "./Math";
import { safeTail } from "./safeTail";

const html = (source: string) => renderToStaticMarkup(<Markdown plainCode>{source}</Markdown>);
const math = (source: string) =>
  renderInline(source).flatMap((node) =>
    isValidElement<{ tex: string }>(node) && node.type === MathInline ? [node.props.tex] : [],
  );

test("keeps shell command dollar signs as plain text without dropping content", () => {
  const source = 'key="$(hybrid_ref_capture.py key .)", then gh api name=hybrid-ref-capture-$key';
  expect(math(source)).toEqual([]);
  const rendered = html(source);
  expect(rendered).not.toContain("cv-math");
  expect(rendered).toContain("$(hybrid_ref_capture.py key .)");
  expect(rendered).toContain("hybrid-ref-capture-$key");
});

test.each(["$PATH and $HOME", "cost $5 and $10", "$(cmd)", "${HOME}"])(
  "keeps shell and currency text literal: %s",
  (source) => {
    expect(math(source)).toEqual([]);
    expect(html(source)).toContain(source);
  },
);

test("requires tight dollar delimiters and a non-alphanumeric character after the closer", () => {
  expect(math("$ x$ $x $ $x$word $x$2")).toEqual([]);
  expect(math("$x^2$ and $\\alpha$ and $E=mc^2$ and $x$")).toEqual(["x^2", "\\alpha", "E=mc^2", "x"]);
});

test("does not parse math inside code and keeps display and backslash math", () => {
  const rendered = html("`$x^2$`\n\n```sh\necho $PATH\n```");
  expect(rendered).not.toContain("cv-math");
  expect(rendered).toContain('<code class="cv-code">$x^2$</code>');
  expect(rendered).toContain("echo $PATH");
  expect(parseMarkdown("$$\nx^2\n$$")[0]).toEqual({ type: "math", tex: "x^2" });
  expect(parseMarkdown("\\(x^2\\)")[0]).toEqual({ type: "paragraph", text: "\\(x^2\\)" });
});

test("explicit backslash math accepts parentheses and braces", () => {
  for (const source of [String.raw`\((x+1)^2\)`, String.raw`\({x}\)`]) {
    const block = parseMarkdown(source)[0];
    expect(block?.type).toBe("paragraph");
    if (block?.type !== "paragraph") throw new Error("missing inline math paragraph");
    expect(math(block.text)).toEqual([source.slice(2, -2)]);
  }
});

test("streaming shell substitutions stay visible and partial equations still wait", () => {
  for (const source of ["$(cmd)", "${HOME}", 'key="$(cmd)" and name=file-$key']) expect(safeTail(source)).toBe(source);
  expect(safeTail("before $x^2")).toBe("before ");
  expect(safeTail(String.raw`before \((x+1)^2`)).toBe("before ");
});
