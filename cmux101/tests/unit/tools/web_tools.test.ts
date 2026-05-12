import { describe, test, expect, beforeEach, afterEach, mock } from "bun:test";
import { webFetchTool } from "../../../src/tools/web_fetch";
import { webSearchTool } from "../../../src/tools/web_search";
import type { ToolContext, PermissionLevel } from "../../../src/core/types";

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function makeCtx(permissionLevel: PermissionLevel = "allow"): ToolContext {
  return {
    cwd: "/tmp",
    abortSignal: new AbortController().signal,
    log: (_level, _text) => {},
    permissions: {
      resolve: (_toolName: string, _input: unknown) => permissionLevel,
      remember: () => {},
      narrow: (_allowedTools: string[]) => makeCtx(permissionLevel).permissions,
    },
    session: {
      meta: {
        id: "test",
        cwd: "/tmp",
        startedAt: new Date().toISOString(),
        providerId: "test",
        model: "test",
      },
      messages: [],
      append: async () => {},
      recordEvent: async () => {},
    },
    spawnSubagent: async () => ({
      text: "",
      usage: { inputTokens: 0, outputTokens: 0 },
      transcriptPath: "",
      ok: false,
    }),
    toolRegistry: {
      get: () => undefined,
      list: () => [],
      toSchemas: () => [],
    },
    emitHook: async () => ({ action: "pass" }),
  };
}

// Save and restore original fetch + process.env between tests
// eslint-disable-next-line @typescript-eslint/no-explicit-any
let originalFetch: any;
let originalEnv: NodeJS.ProcessEnv;

beforeEach(() => {
  originalFetch = globalThis.fetch;
  originalEnv = { ...process.env };
});

afterEach(() => {
  globalThis.fetch = originalFetch;
  // Restore env: remove keys added, restore removed
  for (const key of Object.keys(process.env)) {
    if (!(key in originalEnv)) {
      delete process.env[key];
    }
  }
  for (const [key, value] of Object.entries(originalEnv)) {
    process.env[key] = value;
  }
});

// ---------------------------------------------------------------------------
// web_fetch
// ---------------------------------------------------------------------------

describe("web_fetch", () => {
  test("converts HTML to clean text", async () => {
    const html = `<!DOCTYPE html>
<html>
<head>
  <title>Test Page</title>
  <style>body { color: red; }</style>
  <script>var x = 1;</script>
</head>
<body>
  <nav><a href="/">Home</a></nav>
  <header><h1>Site Header</h1></header>
  <main>
    <h1>Main Heading</h1>
    <p>Hello <b>world</b>! This is a paragraph.</p>
    <ul>
      <li>Item one</li>
      <li>Item two</li>
    </ul>
    <br>
    <p>Second paragraph with &amp; entity.</p>
  </main>
  <footer>Footer text</footer>
</body>
</html>`;

    (globalThis as any).fetch = async (_url: RequestInfo | URL, _init?: RequestInit) => {
      return new Response(html, {
        status: 200,
        headers: { "Content-Type": "text/html; charset=utf-8" },
      });
    };

    const ctx = makeCtx();
    const result = await (webFetchTool.run as Function)(
      { url: "https://example.com/" },
      ctx
    );

    expect(result.isError).toBeUndefined();
    const content = result.content as string;

    // Header line present
    expect(content).toContain("URL: https://example.com/");
    expect(content).toContain("Status: 200");
    expect(content).toContain("Content-Type: text/html; charset=utf-8");

    // Main heading and paragraph
    expect(content).toContain("Main Heading");
    expect(content).toContain("Hello");
    expect(content).toContain("world");
    expect(content).toContain("This is a paragraph.");

    // List items with bullets
    expect(content).toContain("Item one");
    expect(content).toContain("Item two");

    // Entity decoded
    expect(content).toContain("&");

    // Script and style content removed
    expect(content).not.toContain("var x = 1");
    expect(content).not.toContain("color: red");

    // Nav/header/footer removed
    expect(content).not.toContain("Footer text");
  });

  test("pretty-prints JSON responses", async () => {
    const jsonData = { name: "cmux101", version: "0.1.0", features: ["search", "fetch"] };

    (globalThis as any).fetch = async (_url: RequestInfo | URL, _init?: RequestInit) => {
      return new Response(JSON.stringify(jsonData), {
        status: 200,
        headers: { "Content-Type": "application/json" },
      });
    };

    const ctx = makeCtx();
    const result = await (webFetchTool.run as Function)(
      { url: "https://api.example.com/info" },
      ctx
    );

    expect(result.isError).toBeUndefined();
    const content = result.content as string;

    // Should be pretty-printed
    expect(content).toContain('"name": "cmux101"');
    expect(content).toContain('"version": "0.1.0"');
    // Multi-line formatting
    expect(content.split("\n").length).toBeGreaterThan(5);
  });

  test("handles non-200 status codes", async () => {
    (globalThis as any).fetch = async (_url: RequestInfo | URL, _init?: RequestInit) => {
      return new Response("Not Found", {
        status: 404,
        headers: { "Content-Type": "text/plain" },
      });
    };

    const ctx = makeCtx();
    const result = await (webFetchTool.run as Function)(
      { url: "https://example.com/missing" },
      ctx
    );

    // Non-200 is still returned (not an error), but status is included
    expect(result.isError).toBeUndefined();
    const content = result.content as string;
    expect(content).toContain("Status: 404");
  });

  test("returns error for binary content", async () => {
    (globalThis as any).fetch = async (_url: RequestInfo | URL, _init?: RequestInit) => {
      return new Response(new Uint8Array([0x89, 0x50, 0x4e, 0x47]).buffer, {
        status: 200,
        headers: { "Content-Type": "image/png" },
      });
    };

    const ctx = makeCtx();
    const result = await (webFetchTool.run as Function)(
      { url: "https://example.com/image.png" },
      ctx
    );

    expect(result.isError).toBe(true);
    expect(result.content as string).toContain("binary content not supported");
    expect(result.content as string).toContain("image/png");
  });

  test("returns plain text as-is", async () => {
    const plainText = "Hello, this is plain text content.\nSecond line.";

    (globalThis as any).fetch = async (_url: RequestInfo | URL, _init?: RequestInit) => {
      return new Response(plainText, {
        status: 200,
        headers: { "Content-Type": "text/plain" },
      });
    };

    const ctx = makeCtx();
    const result = await (webFetchTool.run as Function)(
      { url: "https://example.com/readme.txt" },
      ctx
    );

    expect(result.isError).toBeUndefined();
    const content = result.content as string;
    expect(content).toContain("Hello, this is plain text content.");
    expect(content).toContain("Second line.");
  });

  test("respects max_bytes limit", async () => {
    const longText = "A".repeat(10_000);

    (globalThis as any).fetch = async (_url: RequestInfo | URL, _init?: RequestInit) => {
      return new Response(longText, {
        status: 200,
        headers: { "Content-Type": "text/plain" },
      });
    };

    const ctx = makeCtx();
    const result = await (webFetchTool.run as Function)(
      { url: "https://example.com/big.txt", max_bytes: 100 },
      ctx
    );

    expect(result.isError).toBeUndefined();
    // The body portion should be capped (header prefix adds some length, but content part <= 100 bytes)
    const content = result.content as string;
    // Full 10000 chars of A should not be present
    expect(content).not.toContain("A".repeat(1000));
  });
});

// ---------------------------------------------------------------------------
// web_search
// ---------------------------------------------------------------------------

describe("web_search", () => {
  test("returns error when no backend configured", async () => {
    delete process.env.BRAVE_SEARCH_API_KEY;
    delete process.env.TAVILY_API_KEY;
    delete process.env.SERPER_API_KEY;

    const ctx = makeCtx();
    const result = await (webSearchTool.run as Function)(
      { query: "TypeScript bun runtime" },
      ctx
    );

    expect(result.isError).toBe(true);
    expect(result.content as string).toContain("No web search backend configured");
    expect(result.content as string).toContain("BRAVE_SEARCH_API_KEY");
    expect(result.content as string).toContain("TAVILY_API_KEY");
    expect(result.content as string).toContain("SERPER_API_KEY");
  });

  test("uses Brave Search when BRAVE_SEARCH_API_KEY is set", async () => {
    delete process.env.TAVILY_API_KEY;
    delete process.env.SERPER_API_KEY;
    process.env.BRAVE_SEARCH_API_KEY = "brave-test-key";

    const braveResponse = {
      web: {
        results: [
          {
            title: "Bun Runtime",
            url: "https://bun.sh",
            description: "A fast JavaScript runtime",
          },
          {
            title: "Bun Docs",
            url: "https://bun.sh/docs",
            description: "Official Bun documentation",
          },
        ],
      },
    };

    let capturedUrl = "";
    let capturedToken = "";
    (globalThis as any).fetch = async (url: RequestInfo | URL, init?: RequestInit) => {
      capturedUrl = url.toString();
      // headers may be a Headers object or plain object
      const headers = init?.headers;
      if (headers instanceof Headers) {
        capturedToken = headers.get("X-Subscription-Token") ?? "";
      } else if (headers && typeof headers === "object") {
        capturedToken = (headers as Record<string, string>)["X-Subscription-Token"] ?? "";
      }
      return new Response(JSON.stringify(braveResponse), {
        status: 200,
        headers: { "Content-Type": "application/json" },
      });
    };

    const ctx = makeCtx();
    const result = await (webSearchTool.run as Function)(
      { query: "bun runtime", num_results: 2 },
      ctx
    );

    expect(result.isError).toBeUndefined();
    const content = result.content as string;
    // Verify the correct backend was called
    expect(capturedUrl).toContain("api.search.brave.com");
    // Header should include the API key
    expect(capturedToken).toBe("brave-test-key");

    // Normalized output format
    expect(content).toContain("1.");
    expect(content).toContain("Bun Runtime");
    expect(content).toContain("https://bun.sh");
    expect(content).toContain("A fast JavaScript runtime");
    expect(content).toContain("2.");
    expect(content).toContain("Bun Docs");
  });

  test("uses Tavily when only TAVILY_API_KEY is set", async () => {
    delete process.env.BRAVE_SEARCH_API_KEY;
    delete process.env.SERPER_API_KEY;
    process.env.TAVILY_API_KEY = "tavily-test-key";

    const tavilyResponse = {
      results: [
        {
          title: "TypeScript Handbook",
          url: "https://www.typescriptlang.org/docs/handbook/",
          content: "The TypeScript Handbook introduces TypeScript to new users.",
        },
      ],
    };

    let capturedUrl = "";
    let capturedBody: Record<string, unknown> = {};
    (globalThis as any).fetch = async (url: RequestInfo | URL, init?: RequestInit) => {
      capturedUrl = url.toString();
      capturedBody = JSON.parse(init?.body as string);
      return new Response(JSON.stringify(tavilyResponse), {
        status: 200,
        headers: { "Content-Type": "application/json" },
      });
    };

    const ctx = makeCtx();
    const result = await (webSearchTool.run as Function)(
      { query: "TypeScript tutorial", num_results: 5 },
      ctx
    );

    expect(result.isError).toBeUndefined();
    const content = result.content as string;

    // Verify the correct backend was called
    expect(capturedUrl).toContain("api.tavily.com");
    // Verify request body
    expect(capturedBody.api_key).toBe("tavily-test-key");
    expect(capturedBody.query).toBe("TypeScript tutorial");
    expect(capturedBody.max_results).toBe(5);

    // Normalized result shape
    expect(content).toContain("1.");
    expect(content).toContain("TypeScript Handbook");
    expect(content).toContain("https://www.typescriptlang.org/docs/handbook/");
    expect(content).toContain("The TypeScript Handbook introduces TypeScript to new users.");
  });

  test("uses Serper when only SERPER_API_KEY is set", async () => {
    delete process.env.BRAVE_SEARCH_API_KEY;
    delete process.env.TAVILY_API_KEY;
    process.env.SERPER_API_KEY = "serper-test-key";

    const serperResponse = {
      organic: [
        {
          title: "MDN Web Docs",
          link: "https://developer.mozilla.org",
          snippet: "Resources for developers, by developers.",
        },
        {
          title: "W3Schools",
          link: "https://www.w3schools.com",
          snippet: "Web development tutorials.",
        },
      ],
    };

    let capturedUrl = "";
    let capturedSerperToken = "";
    (globalThis as any).fetch = async (url: RequestInfo | URL, init?: RequestInit) => {
      capturedUrl = url.toString();
      const headers = init?.headers;
      if (headers instanceof Headers) {
        capturedSerperToken = headers.get("X-API-KEY") ?? "";
      } else if (headers && typeof headers === "object") {
        capturedSerperToken = (headers as Record<string, string>)["X-API-KEY"] ?? "";
      }
      return new Response(JSON.stringify(serperResponse), {
        status: 200,
        headers: { "Content-Type": "application/json" },
      });
    };

    const ctx = makeCtx();
    const result = await (webSearchTool.run as Function)(
      { query: "web docs", num_results: 2 },
      ctx
    );

    expect(result.isError).toBeUndefined();
    const content = result.content as string;

    expect(capturedUrl).toContain("google.serper.dev");
    expect(capturedSerperToken).toBe("serper-test-key");

    // Normalized result shape
    expect(content).toContain("1.");
    expect(content).toContain("MDN Web Docs");
    expect(content).toContain("https://developer.mozilla.org");
    expect(content).toContain("Resources for developers, by developers.");
    expect(content).toContain("2.");
    expect(content).toContain("W3Schools");
  });

  test("prefers Brave over Tavily and Serper when all keys set", async () => {
    process.env.BRAVE_SEARCH_API_KEY = "brave-key";
    process.env.TAVILY_API_KEY = "tavily-key";
    process.env.SERPER_API_KEY = "serper-key";

    let calledUrl = "";
    (globalThis as any).fetch = async (url: RequestInfo | URL, _init?: RequestInit) => {
      calledUrl = url.toString();
      return new Response(
        JSON.stringify({ web: { results: [{ title: "Result", url: "https://r.com", description: "desc" }] } }),
        { status: 200, headers: { "Content-Type": "application/json" } }
      );
    };

    const ctx = makeCtx();
    await (webSearchTool.run as Function)({ query: "test" }, ctx);

    expect(calledUrl).toContain("api.search.brave.com");
  });

  test("normalized result shape contains title, url, snippet", async () => {
    delete process.env.BRAVE_SEARCH_API_KEY;
    delete process.env.SERPER_API_KEY;
    process.env.TAVILY_API_KEY = "tavily-test-key";

    const tavilyResponse = {
      results: [
        { title: "My Title", url: "https://mytitle.com", content: "My snippet text." },
      ],
    };

    (globalThis as any).fetch = async () =>
      new Response(JSON.stringify(tavilyResponse), {
        status: 200,
        headers: { "Content-Type": "application/json" },
      });

    const ctx = makeCtx();
    const result = await (webSearchTool.run as Function)({ query: "my query" }, ctx);

    expect(result.isError).toBeUndefined();
    const content = result.content as string;

    // Must have numbered format, URL label, and snippet
    expect(content).toMatch(/^1\./m);
    expect(content).toContain("My Title");
    expect(content).toContain("URL: https://mytitle.com");
    expect(content).toContain("My snippet text.");
  });
});
