// l10n-allow-file: test fixtures.
// A tool result's Markdown (toolResult.ts, drawn by ToolRow with `plainCode`) draws every fence as
// plain code, nested ones included: tool text never becomes a diagram or a render card.
import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { Markdown } from "./Markdown";

test("fences in a tool result's quotes and list items stay plain code, as at the top", () => {
  // Codex review finding 1: `plainCode` reached only top-level fences.
  const text =
    "> ```mermaid\n> graph TD; A-->B\n> ```\n\n- Item\n\n  ```html\n  <b>x</b>\n  ```\n\n```svg\n<svg/>\n```";
  const html = renderToStaticMarkup(<Markdown plainCode>{text}</Markdown>);
  expect(html.match(/cv-codeblock--plain/g)).toHaveLength(3);
});
