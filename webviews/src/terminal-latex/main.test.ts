import { expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { renderEquation, updatePreview } from "./main";

test("renders inline and block TeX as native MathML", () => {
  expect(renderEquation(String.raw`\frac{a}{b}`, false)).toContain("<mfrac>");
  expect(renderEquation(String.raw`\sum_{i=1}^n i`, true)).toContain('display="block"');
  expect(renderEquation(String.raw`\begin{pmatrix}a&b\\c&d\end{pmatrix}`, true)).toContain("<mtable");
});

test("invalid or hostile math cannot hide terminal source or load external content", () => {
  expect(renderEquation(String.raw`\frac{a}{`, false)).toBeNull();
  expect(renderEquation(String.raw`\unsupported{x}`, false)).toBeNull();
  expect(renderEquation(String.raw`\def\a{\a}\a`, false)).toBeNull();
  for (const source of [
    String.raw`\href{javascript:alert(1)}{x}`,
    String.raw`\includegraphics{https://example.com/tracker}`,
    String.raw`\htmlStyle{position:fixed}{x}`,
    String.raw`\text{<script>alert(1)</script>}`,
  ]) {
    const document = new JSDOM(renderEquation(source, false) ?? "").window.document;
    expect(document.querySelector("script, img, a, [href], [src], [onerror]")).toBeNull();
  }
});

test("replaces source cells only after rendering and removes previews on rewrite", () => {
  const dom = new JSDOM('<div id="equations"></div>');
  const previous = globalThis.document;
  globalThis.document = dom.window.document;
  try {
    const region = { column: 4, row: 2, width: 10, height: 1 };
    const preview = {
      equations: [{ source: "x^2", display: false, regions: [region], layout: region }],
      cellWidth: 8, cellHeight: 20, paddingLeft: 7, paddingTop: 9,
      foreground: "#ffffff", background: "#000000",
    };
    updatePreview(preview);
    expect(document.querySelectorAll("math").length).toBe(1);
    const mask = document.querySelector<HTMLElement>("#equations > div > div");
    expect(mask?.style.left).toBe("39px");
    expect(mask?.style.top).toBe("49px");
    preview.equations[0].source = String.raw`\frac{`;
    updatePreview(preview);
    expect(document.getElementById("equations")?.childElementCount).toBe(0);
    updatePreview({ ...preview, equations: [] });
    expect(document.querySelector("math")).toBeNull();
  } finally {
    globalThis.document = previous;
    dom.window.close();
  }
});
