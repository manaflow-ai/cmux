import { describe, expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { Markdown } from "./Markdown";

const CHART = `{"mark": "bar", "data": {"values": [{"target": "app", "s": 312}]}, "encoding": {"x": {"field": "target"}, "y": {"field": "s", "type": "quantitative"}}}`;

describe("charts in a reply", () => {
  test("a vega-lite fence draws as a chart frame that keeps its source, not a code block", () => {
    const html = renderToStaticMarkup(<Markdown>{"Build times:\n\n```vega-lite\n" + CHART + "\n```\n"}</Markdown>);
    expect(html).toContain('class="cv-diagram"');
    expect(html).toContain('data-language="vega-lite"');
    expect(html).not.toContain("cv-code");
  });

  test("a fence still streaming, or one that is not JSON, stays code", () => {
    expect(renderToStaticMarkup(<Markdown streaming>{'```vega-lite\n{"mark": "bar"'}</Markdown>)).not.toContain(
      "cv-diagram",
    );
    expect(renderToStaticMarkup(<Markdown>{"```vega-lite\nnot json\n```\n"}</Markdown>)).not.toContain("cv-diagram");
  });

  test("mermaid stays code until the shared diagram worker draws it", () => {
    expect(renderToStaticMarkup(<Markdown>{"```mermaid\ngraph TD; A-->B\n```\n"}</Markdown>)).not.toContain(
      "cv-diagram",
    );
  });
});
