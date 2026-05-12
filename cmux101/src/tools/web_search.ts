import { z } from "zod";
import type { Tool, ToolContext, ToolResult } from "../core/types";

const TIMEOUT_MS = 15_000;
const USER_AGENT = "cmux101/0.1";

interface SearchResult {
  title: string;
  url: string;
  snippet: string;
}

function formatResults(results: SearchResult[]): string {
  return results
    .map(
      (r, i) =>
        `${i + 1}. ${r.title}\n   URL: ${r.url}\n   ${r.snippet}`
    )
    .join("\n\n");
}

async function searchBrave(
  query: string,
  numResults: number,
  apiKey: string,
  signal: AbortSignal
): Promise<SearchResult[]> {
  const url = `https://api.search.brave.com/res/v1/web/search?q=${encodeURIComponent(query)}&count=${numResults}`;
  const response = await fetch(url, {
    signal,
    headers: {
      "Accept": "application/json",
      "Accept-Encoding": "gzip",
      "X-Subscription-Token": apiKey,
      "User-Agent": USER_AGENT,
    },
  });
  if (!response.ok) {
    throw new Error(`Brave Search API error: ${response.status} ${response.statusText}`);
  }
  const data = (await response.json()) as {
    web?: { results?: Array<{ title?: string; url?: string; description?: string }> };
  };
  const rawResults = data?.web?.results ?? [];
  return rawResults.map((r) => ({
    title: r.title ?? "",
    url: r.url ?? "",
    snippet: r.description ?? "",
  }));
}

async function searchTavily(
  query: string,
  numResults: number,
  apiKey: string,
  signal: AbortSignal
): Promise<SearchResult[]> {
  const response = await fetch("https://api.tavily.com/search", {
    method: "POST",
    signal,
    headers: {
      "Content-Type": "application/json",
      "User-Agent": USER_AGENT,
    },
    body: JSON.stringify({ api_key: apiKey, query, max_results: numResults }),
  });
  if (!response.ok) {
    throw new Error(`Tavily API error: ${response.status} ${response.statusText}`);
  }
  const data = (await response.json()) as {
    results?: Array<{ title?: string; url?: string; content?: string }>;
  };
  const rawResults = data?.results ?? [];
  return rawResults.map((r) => ({
    title: r.title ?? "",
    url: r.url ?? "",
    snippet: r.content ?? "",
  }));
}

async function searchSerper(
  query: string,
  numResults: number,
  apiKey: string,
  signal: AbortSignal
): Promise<SearchResult[]> {
  const response = await fetch("https://google.serper.dev/search", {
    method: "POST",
    signal,
    headers: {
      "Content-Type": "application/json",
      "X-API-KEY": apiKey,
      "User-Agent": USER_AGENT,
    },
    body: JSON.stringify({ q: query, num: numResults }),
  });
  if (!response.ok) {
    throw new Error(`Serper API error: ${response.status} ${response.statusText}`);
  }
  const data = (await response.json()) as {
    organic?: Array<{ title?: string; link?: string; snippet?: string }>;
  };
  const rawResults = data?.organic ?? [];
  return rawResults.slice(0, numResults).map((r) => ({
    title: r.title ?? "",
    url: r.link ?? "",
    snippet: r.snippet ?? "",
  }));
}

export const webSearchTool: Tool = {
  name: "web_search",
  description: "Search the web. Returns titles, URLs, and snippets.",
  inputSchema: z.object({
    query: z.string(),
    num_results: z.number().int().positive().max(20).optional(),
  }),
  defaultPermission: "allow",

  async run(input: unknown, ctx: ToolContext): Promise<ToolResult> {
    const parsed = (webSearchTool.inputSchema as ReturnType<typeof z.object>).parse(
      input
    ) as { query: string; num_results?: number };

    const { query } = parsed;
    const numResults = parsed.num_results ?? 10;

    ctx.log("debug", `web_search: ${query}`);

    const braveKey = process.env.BRAVE_SEARCH_API_KEY;
    const tavilyKey = process.env.TAVILY_API_KEY;
    const serperKey = process.env.SERPER_API_KEY;

    if (!braveKey && !tavilyKey && !serperKey) {
      return {
        content:
          "No web search backend configured. Set BRAVE_SEARCH_API_KEY, TAVILY_API_KEY, or SERPER_API_KEY.",
        isError: true,
      };
    }

    // Timeout + abort combining
    const ac = new AbortController();
    const timeoutId = setTimeout(() => ac.abort(new Error("Timeout after 15s")), TIMEOUT_MS);
    const onParentAbort = () => ac.abort(ctx.abortSignal.reason);
    ctx.abortSignal.addEventListener("abort", onParentAbort, { once: true });

    try {
      let results: SearchResult[];

      try {
        if (braveKey) {
          results = await searchBrave(query, numResults, braveKey, ac.signal);
        } else if (tavilyKey) {
          results = await searchTavily(query, numResults, tavilyKey, ac.signal);
        } else {
          results = await searchSerper(query, numResults, serperKey!, ac.signal);
        }
      } catch (err: unknown) {
        const msg = err instanceof Error ? err.message : String(err);
        return { content: `Search error: ${msg}`, isError: true };
      }

      if (results.length === 0) {
        return { content: `No results found for: ${query}` };
      }

      return { content: formatResults(results) };
    } finally {
      clearTimeout(timeoutId);
      ctx.abortSignal.removeEventListener("abort", onParentAbort);
    }
  },
};
