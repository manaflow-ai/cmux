import { describe, expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { Markdown, type UrlRewriter } from "../app/extensions/_lib/markdown";

const keep: UrlRewriter = (href) => (href.startsWith("javascript:") ? null : href);
const html = (source: string, url: UrlRewriter = keep) => renderToStaticMarkup(<Markdown source={source} url={url} />);

describe("README markdown", () => {
  test("renders the blocks READMEs use", () => {
    const out = html([
      "# Title", "", "Some *em*, **strong**, `code` and ~~gone~~.", "", "```sh", "echo <hi>", "```", "",
      "> quoted", "", "- one", "- [x] done", "  - nested", "", "1. first", "2. second", "", "---", "",
      "| a | b |", "|:--|--:|", "| 1 | 2 |",
    ].join("\n"));
    expect(out).toContain("<h1>Title</h1>");
    expect(out).toContain("<em>em</em>");
    expect(out).toContain("<strong>strong</strong>");
    expect(out).toContain("<code>code</code>");
    expect(out).toContain("<del>gone</del>");
    expect(out).toContain('<pre><code data-language="sh">echo &lt;hi&gt;</code></pre>');
    expect(out).toContain("<blockquote><p>quoted</p></blockquote>");
    expect(out).toContain('type="checkbox"');
    expect(out).toContain("<li>nested</li>");
    expect(out).toContain("<ol><li>first</li><li>second</li></ol>");
    expect(out).toContain("<hr/>");
    expect(out).toContain('<th align="left">a</th>');
    expect(out).toContain('<td align="right">2</td>');
  });

  test("links and images go through the URL rewriter", () => {
    const seen: string[] = [];
    const out = html("[docs](docs/a.md) ![shot](img.png) <https://e.test/x> https://e.test/y", (href, kind) => {
      seen.push(`${kind}:${href}`);
      return `https://r.test/${href}`;
    });
    expect(seen).toEqual(["link:docs/a.md", "image:img.png", "link:https://e.test/x", "link:https://e.test/y"]);
    expect(out).toContain('href="https://r.test/docs/a.md" rel="nofollow ugc noopener noreferrer"');
    expect(out).toContain('src="https://r.test/img.png"');
  });

  test("raw HTML keeps only safe tags and attributes", () => {
    const out = html([
      '<p align="center"><img src="logo.png" width="120" onerror="alert(1)" style="x"></p>',
      "",
      '<script>alert(1)</script><iframe src="https://e.test"></iframe><style>body{}</style>',
      "",
      '<a href="javascript:alert(1)" onclick="x">bad</a> <details><summary>More</summary>hidden</details>',
      "",
      '<picture><source srcset="dark.png 2x" media="(prefers-color-scheme: dark)"><img src="light.png"></picture>',
    ].join("\n"));
    expect(out).toContain('<p align="center"><img src="logo.png" width="120"');
    expect(out).not.toMatch(/onerror|onclick|style=|<script|<iframe|<style|alert\(|body\{\}|javascript:/);
    expect(out).toContain("<a>bad</a>");
    expect(out).toContain("<details><summary>More</summary>hidden</details>");
    expect(out).toContain('srcSet="dark.png"');
  });

  test("text is never HTML", () => {
    const out = html("a <b onclick=x>b</b> &lt;i&gt; &amp; \\*not em\\*");
    expect(out).toContain("<b>b</b>");
    expect(out).toContain("&lt;i&gt; &amp; *not em*");
  });

  test("an image whose URL is dropped is not rendered", () => {
    expect(html("![x](javascript:void)")).toBe("<p></p>");
  });
});
