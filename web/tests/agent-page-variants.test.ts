import { describe, expect, test } from "bun:test";
import {
  buildLlmsText,
  resolveAgentPageVariant,
  variantPathForPage,
} from "../app/lib/agent-page-paths";
import {
  headersForAgentPage,
  markdownFromHtml,
  plainTextFromMarkdown,
} from "../app/lib/agent-page-markdown";
import { headersForCanonicalFetch } from "../app/lib/agent-page-canonical-fetch";

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
    expect(resolveAgentPageVariant("/undocumented-internal-feature.md")).toBeNull();
    expect(resolveAgentPageVariant("/%5Cfoo.md")).toBeNull();
    expect(resolveAgentPageVariant("/%00foo.md")).toBeNull();
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
              <p><a href="/download">Download</a><a href="/github">GitHub</a></p>
              <a href="/blog/post">
                <h2>Post Title</h2>
                <p>Post summary.</p>
              </a>
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
    expect(markdown).toContain("[Download](https://cmux.com/download) [GitHub](https://cmux.com/github)");
    expect(markdown).toContain("## Post Title");
    expect(markdown).toContain("Link: https://cmux.com/blog/post");
    expect(markdown).not.toContain("](https://cmux.com/blog/post)");
    expect(markdown).toContain("| Command | Description |");
    expect(markdown).toContain("```");
    expect(markdown).toContain("Canonical: https://cmux.com/docs");
    expect(markdown).not.toContain("Skip this");
  });

  test("uses the document title when readable HTML has no top-level heading", () => {
    const markdown = markdownFromHtml({
      html: `
        <html>
          <head><title>Settings &amp; Docs &#39;Guide&#39; \u2014 cmux</title></head>
          <body>
            <main><p>Configure cmux.</p></main>
          </body>
        </html>`,
      origin: "https://cmux.com",
      sourceUrl: "https://cmux.com/docs/configuration",
    });

    expect(markdown).toStartWith("# Settings & Docs 'Guide'\n\nConfigure cmux.");
  });

  test("moves the page title before backlinks and media", () => {
    const markdown = markdownFromHtml({
      html: `
        <html>
          <body>
            <main>
              <a href="/blog">Back to blog</a>
              <img src="/logo.png" alt="cmux icon" />
              <h1>Post Title</h1>
              <p>Body text.</p>
            </main>
          </body>
        </html>`,
      origin: "https://cmux.com",
      sourceUrl: "https://cmux.com/blog/post",
    });

    expect(markdown).toStartWith("# Post Title\n\n[Back to blog]");
    expect(markdown.match(/^# Post Title$/gm)).toHaveLength(1);
  });

  test("keeps code intact while cleaning Markdown", () => {
    const markdown = markdownFromHtml({
      html: `
        <html>
          <body>
            <main>
              <h1>Code</h1>
              <p><code>arr.map(fn)[0]</code></p>
              <pre><code>arr.map(fn)[0]</code></pre>
            </main>
          </body>
        </html>`,
      origin: "https://cmux.com",
      sourceUrl: "https://cmux.com/docs/code",
    });

    expect(markdown).toContain("arr.map(fn)[0]");
    expect(markdown).not.toContain("arr.map(fn) [0]");
  });

  test("converts Markdown variants to readable plain text", () => {
    const text = plainTextFromMarkdown(
      [
        "# Docs",
        "",
        "![cmux icon](https://cmux.com/logo.png)",
        "",
        "Read the [API docs](https://cmux.com/docs/api).",
        "",
        "| Command | Description |",
        "| --- | --- |",
        "| `cmux list-workspaces` | List workspaces. |",
        "",
        "```",
        "arr.map(fn)[0]",
        "```",
        "",
        "Canonical: https://cmux.com/docs",
      ].join("\n"),
    );

    expect(text).toContain("Docs");
    expect(text).toContain("cmux icon (https://cmux.com/logo.png)");
    expect(text).toContain("API docs (https://cmux.com/docs/api)");
    expect(text).toContain("Command\tDescription");
    expect(text).toContain("cmux list-workspaces\tList workspaces.");
    expect(text).toContain("arr.map(fn)[0]");
    expect(text).not.toContain("```");
    expect(text).not.toContain("![cmux icon]");
    expect(text).not.toContain("[API docs]");
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

  test("keeps personalized variant responses out of shared caches", () => {
    const headers = headersForAgentPage({
      canonicalUrl: "https://cmux.com/docs/getting-started",
      contentLanguage: "en",
      format: "txt",
      privateResponse: true,
      varyAcceptLanguage: true,
    });

    expect(headers.get("content-type")).toBe("text/plain; charset=utf-8");
    expect(headers.get("cache-control")).toBe("private, no-store");
    expect(headers.get("vary")).toBe("Accept-Language");
  });

  test("forwards protected preview auth headers to canonical HTML fetches", () => {
    const requestHeaders = new Headers({
      cookie: "_vercel_sso_nonce=abc; NEXT_LOCALE=ja",
      "accept-language": "ja,en;q=0.9",
      authorization: "Bearer token",
    });
    const searchParams = new URLSearchParams({
      "x-vercel-protection-bypass": "secret",
      "x-vercel-set-bypass-cookie": "true",
    });
    const headers = headersForCanonicalFetch({ requestHeaders, searchParams });

    expect(headers.get("accept")).toBe("text/html");
    expect(headers.get("cookie")).toContain("_vercel_sso_nonce=abc");
    expect(headers.get("accept-language")).toBe("ja,en;q=0.9");
    expect(headers.get("authorization")).toBe("Bearer token");
    expect(headers.get("x-vercel-protection-bypass")).toBe("secret");
    expect(headers.get("x-vercel-set-bypass-cookie")).toBe("true");
  });

  test("lists agent-readable Markdown and text variants", () => {
    const llms = buildLlmsText("https://cmux.com");

    expect(llms).toContain("[Getting Started](https://cmux.com/docs/getting-started.md)");
    expect(llms).toContain("Text: https://cmux.com/docs/getting-started.txt");
    expect(variantPathForPage("/", "md")).toBe("/index.md");
  });
});
