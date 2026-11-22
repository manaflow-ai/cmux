// The fixture corpus (fixtures/*.md): realistic agent replies, heavy on math, code, tables and
// lists. Each renders whole, and the math-heavy one also renders at every prefix as it streams,
// where no frame may show TeX source that a later frame turns into math.
import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { renderToStaticMarkup } from "react-dom/server";
import { Markdown, footnoteOrder, parseMarkdown } from "./Markdown";

const fixture = (name: string) => readFileSync(new URL(`./fixtures/${name}.md`, import.meta.url), "utf8");
const html = (source: string, streaming = false) =>
  renderToStaticMarkup(<Markdown streaming={streaming}>{source}</Markdown>);

/// The text a reader sees: no tags, no MathML annotation (it carries the TeX), no code.
function visibleText(markup: string): string {
  return markup
    .replace(/<annotation[^>]*>[\s\S]*?<\/annotation>/g, "")
    .replace(/<code[^>]*>[\s\S]*?<\/code>/g, "")
    .replace(/<[^>]+>/g, "")
    .replace(/&amp;/g, "&")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">");
}

/// TeX source drawn as text: a delimiter or a command the fixture uses.
const TEX_SOURCE = /\\\(|\\\[|\$\$|\\(?:frac|tfrac|sum|int|begin|end|Theta|pmatrix)\b|\$[A-Za-z\\({]/;

describe("math-heavy reply", () => {
  const source = fixture("math-heavy");

  test("every equation is typeset and none draws as source", () => {
    const out = html(source);
    // Inline, display, \( \), \[ \] with an aligned environment, a matrix, and math in table cells.
    expect(out.match(/class="katex"/g)!.length).toBe(17);
    expect(out.match(/class="katex-display"/g)!.length).toBe(4);
    expect(out).not.toContain("cv-math-source");
    expect(visibleText(out).replace("$HOME", "")).not.toMatch(TEX_SOURCE);
  });

  test("prices, code and escaped dollars stay text", () => {
    const text = visibleText(html(source));
    expect(text).toContain("A price like $5 or $10 is not math");
    expect(text).toContain("$HOME");
    expect(html(source)).toContain('<code class="cv-code">$PATH</code>');
  });

  test("a display equation over several lines is one block", () => {
    const blocks = parseMarkdown(source).filter((block) => block.type === "math");
    expect(blocks.map((block) => block.type === "math" && block.tex.split("\n")[0])).toEqual([
      "S_n - S_{n-1} = n^2",
      "\\begin{aligned} 3a &= 1, \\\\ -3a + 2b &= 0, \\\\ a - b + c &= 0. \\end{aligned}",
      "S_n = \\frac{n(n+1)(2n+1)}{6}.",
      "\\begin{pmatrix} 1 & 1 & 1 \\\\ 8 & 4 & 2 \\\\ 27 & 9 & 3 \\end{pmatrix}\\begin{pmatrix} a \\\\ b \\\\ c \\end{pmatrix} = \\begin{pmatrix} 1 \\\\ 5 \\\\ 14 \\end{pmatrix}",
    ]);
  });

  test("while it streams, no frame draws half an equation as source", () => {
    for (let end = 1; end <= source.length; end += 1) {
      const text = visibleText(html(source.slice(0, end), true));
      // The escaped `\$HOME` draws its dollar as it arrives.
      const shown = text.replace(/\$H(?:O(?:M(?:E)?)?)?/, "");
      if (TEX_SOURCE.test(shown)) throw new Error(`frame ${end} shows TeX source: ${JSON.stringify(shown.slice(-80))}`);
    }
  });
});

describe("code-heavy reply", () => {
  test("every fence is a code card with its language", () => {
    const blocks = parseMarkdown(fixture("code-heavy")).filter((block) => block.type === "code");
    expect(blocks.map((block) => block.type === "code" && block.lang)).toEqual(["ts", "swift", "bash", "diff", "text"]);
  });
});

describe("tables and lists reply", () => {
  const out = html(fixture("tables-lists"));

  test("nested ordered and bullet lists, tasks and a quote", () => {
    expect(out).toContain('class="cv-list cv-ol" data-depth="0"');
    expect(out).toContain('class="cv-list cv-ul" data-depth="1"');
    expect(out).toContain('class="cv-list cv-ol" data-depth="1"');
    // The checked box also contains `cv-checkbox__check` on its SVG; count the exact element
    // class so the check mark does not look like a fourth task checkbox.
    expect(out.match(/class="[^"]*\bcv-checkbox\b[^"]*"/g)!.length).toBe(3);
    expect(out).toContain('<blockquote class="cv-quote">');
  });

  test("the table sits in a scroll box with every column aligned", () => {
    expect(out).toContain('<div class="cv-table-wrap"><table class="cv-table">');
    expect(out).toContain("text-align:center");
    expect(out).toContain("text-align:right");
    expect(out.match(/<tr>/g)!.length).toBe(5);
  });
});

describe("references reply", () => {
  const source = fixture("references");
  const out = html(source);

  test("footnotes number by first reference and draw as notes at the end", () => {
    expect(footnoteOrder(source)).toEqual(["bisect", "upstream"]);
    expect(out.match(/class="cv-fnref"/g)!.length).toBe(3);
    const notes = out.slice(out.indexOf('class="cv-footnotes"'));
    expect(notes.indexOf("git bisect")).toBeLessThan(notes.indexOf("which also covers the Linux case"));
    expect(out).not.toContain("[^bisect]");
    expect(out).not.toContain("[^upstream]:");
    // Regex classes, in code or not, stay text.
    expect(visibleText(out)).toContain("[^a-z]");
  });

  test("h5 and h6 draw as the smallest heading", () => {
    expect(out).toContain('<h5 class="cv-h cv-h4">Minor heading</h5>');
    expect(out).toContain('<h6 class="cv-h cv-h4">Smallest heading</h6>');
  });

  test("a data URL image draws; a web image waits behind a placeholder with its site (D5)", () => {
    expect(out).toContain('<img class="cv-img" src="data:image/png;base64,');
    expect(out).toMatch(
      /<span class="cv-image-placeholder" title="https:\/\/example.com\/assets\/build-graph.png">.*example.com<\/span><button[^>]*>Load image<\/button>/,
    );
    expect(out).not.toContain("![");
  });

  test("while it streams, a footnote reference shows as soon as it closes", () => {
    const frame = html("Fixed in 0.64[^bisect] since", true);
    expect(frame).toContain('class="cv-fnref"');
    expect(visibleText(frame)).toContain(" since");
  });
});
