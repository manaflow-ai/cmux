import { describe, expect, test } from "bun:test";
import {
  buildLlmsText,
  resolveAgentPageVariant,
  variantPathForPage,
} from "../app/lib/agent-page-paths";
import {
  headersForAgentPage,
  markdownFromHtml,
} from "../app/lib/agent-page-markdown";

describe("agent page variants", () => {
  test("maps Markdown and text extension paths to canonical HTML pages", () => {
    expect(resolveAgentPageVariant("/docs/getting-started.md")).toEqual({
      kind: "page",
      format: "md",
      requestedPath: "/docs/getting-started.md",
      canonicalPath: "/docs/getting-started",
    });
    expect(resolveAgentPageVariant("/en/docs/getting-started.txt")).toEqual({
      kind: "page",
      format: "txt",
      requestedPath: "/en/docs/getting-started.txt",
      canonicalPath: "/docs/getting-started",
    });
    expect(resolveAgentPageVariant("/ja/index.md")).toEqual({
      kind: "page",
      format: "md",
      requestedPath: "/ja/index.md",
      canonicalPath: "/ja",
    });
  });

  test("keeps reserved text endpoints out of page variant routing", () => {
    expect(resolveAgentPageVariant("/robots.txt")).toBeNull();
    expect(resolveAgentPageVariant("/api/status.txt")).toBeNull();
    expect(resolveAgentPageVariant("/llms.txt")).toEqual({
      kind: "llms",
      requestedPath: "/llms.txt",
    });
  });

  test("renders main HTML as GitHub-flavored Markdown", () => {
    const markdown = markdownFromHtml({
      html: `
        <html>
          <head><title>Ignored title</title></head>
          <body>
            <nav>Skip this</nav>
            <main>
              <h1>Docs</h1>
              <p>Read the <a href="/docs/api">API docs</a>.</p>
              <table>
                <thead><tr><th>Command</th><th>Description</th></tr></thead>
                <tbody><tr><td><code>cmux list-workspaces</code></td><td>List workspaces.</td></tr></tbody>
              </table>
              <pre><code>cmux notify --title Done</code></pre>
            </main>
          </body>
        </html>`,
      origin: "https://cmux.com",
      sourceUrl: "https://cmux.com/docs",
    });

    expect(markdown).toContain("# Docs");
    expect(markdown).toContain("[API docs](https://cmux.com/docs/api)");
    expect(markdown).toContain("| Command | Description |");
    expect(markdown).toContain("```");
    expect(markdown).toContain("Canonical: https://cmux.com/docs");
    expect(markdown).not.toContain("Skip this");
  });

  test("marks alternate text responses as non-indexable canonical variants", () => {
    const headers = headersForAgentPage({
      canonicalUrl: "https://cmux.com/docs/getting-started",
      contentLanguage: "en",
      format: "md",
    });

    expect(headers.get("content-type")).toBe("text/markdown; charset=utf-8");
    expect(headers.get("x-robots-tag")).toBe("noindex, follow");
    expect(headers.get("link")).toBe(
      '<https://cmux.com/docs/getting-started>; rel="canonical"',
    );
  });

  test("lists agent-readable Markdown and text variants", () => {
    const llms = buildLlmsText("https://cmux.com");

    expect(llms).toContain("[Getting Started](https://cmux.com/docs/getting-started.md)");
    expect(llms).toContain("Text: https://cmux.com/docs/getting-started.txt");
    expect(variantPathForPage("/", "md")).toBe("/index.md");
  });
});
