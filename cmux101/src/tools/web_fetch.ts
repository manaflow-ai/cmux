import { z } from "zod";
import type { Tool, ToolContext, ToolResult } from "../core/types";

const DEFAULT_MAX_BYTES = 2 * 1024 * 1024; // 2 MB
const USER_AGENT = "cmux101/0.1";
const TIMEOUT_MS = 30_000;
const MAX_REDIRECTS = 5;

/**
 * Convert an HTML string to clean text without external libraries.
 * Strategy:
 *   1. Remove <script>...</script> and <style>...</style> blocks.
 *   2. Remove semantic nav/header/footer tags and their contents.
 *   3. Insert newlines before block-level / structural tags.
 *   4. Strip all remaining HTML tags.
 *   5. Decode common HTML entities.
 *   6. Collapse whitespace.
 */
function htmlToText(html: string): string {
  let text = html;

  // Remove script and style blocks (including content)
  text = text.replace(/<script\b[^>]*>[\s\S]*?<\/script>/gi, "");
  text = text.replace(/<style\b[^>]*>[\s\S]*?<\/style>/gi, "");

  // Remove nav, header, footer, aside (and their content)
  text = text.replace(/<nav\b[^>]*>[\s\S]*?<\/nav>/gi, "");
  text = text.replace(/<header\b[^>]*>[\s\S]*?<\/header>/gi, "");
  text = text.replace(/<footer\b[^>]*>[\s\S]*?<\/footer>/gi, "");
  text = text.replace(/<aside\b[^>]*>[\s\S]*?<\/aside>/gi, "");

  // Insert newlines before block-level tags
  // Headings: add ## prefix marker
  text = text.replace(/<h[1-6]\b[^>]*>/gi, "\n\n");
  text = text.replace(/<\/h[1-6]>/gi, "\n");

  // Paragraphs, divs, sections, articles
  text = text.replace(/<\/?(?:p|div|section|article|main|blockquote)\b[^>]*>/gi, "\n");

  // List items: add a bullet
  text = text.replace(/<li\b[^>]*>/gi, "\n• ");
  text = text.replace(/<\/li>/gi, "");

  // Unordered/ordered lists
  text = text.replace(/<\/?(?:ul|ol|dl)\b[^>]*>/gi, "\n");

  // Line breaks
  text = text.replace(/<br\s*\/?>/gi, "\n");

  // Horizontal rules
  text = text.replace(/<hr\s*\/?>/gi, "\n---\n");

  // Table cells / rows
  text = text.replace(/<\/(?:td|th)>/gi, "\t");
  text = text.replace(/<\/tr>/gi, "\n");

  // Strip all remaining HTML tags
  text = text.replace(/<[^>]+>/g, "");

  // Decode common HTML entities
  text = text
    .replace(/&amp;/g, "&")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/&apos;/g, "'")
    .replace(/&nbsp;/g, " ")
    .replace(/&#(\d+);/g, (_, code) => String.fromCharCode(Number(code)))
    .replace(/&#x([0-9a-f]+);/gi, (_, hex) => String.fromCharCode(parseInt(hex, 16)));

  // Collapse runs of spaces/tabs on the same line (but preserve newlines)
  text = text.replace(/[^\S\n]+/g, " ");

  // Collapse 3+ consecutive newlines to 2
  text = text.replace(/\n{3,}/g, "\n\n");

  // Trim leading/trailing whitespace per line
  text = text
    .split("\n")
    .map((line) => line.trim())
    .join("\n");

  return text.trim();
}

export const webFetchTool: Tool = {
  name: "web_fetch",
  description:
    "Fetch a URL and return its content. HTML is converted to clean markdown-ish text.",
  inputSchema: z.object({
    url: z.string().url(),
    max_bytes: z.number().int().positive().optional(),
  }),
  defaultPermission: "allow",

  async run(input: unknown, ctx: ToolContext): Promise<ToolResult> {
    const parsed = (webFetchTool.inputSchema as ReturnType<typeof z.object>).parse(
      input
    ) as { url: string; max_bytes?: number };

    const { url } = parsed;
    const maxBytes = parsed.max_bytes ?? DEFAULT_MAX_BYTES;

    ctx.log("debug", `web_fetch: ${url}`);

    // Timeout + abort signal combining
    const ac = new AbortController();
    const timeoutId = setTimeout(() => ac.abort(new Error("Timeout after 30s")), TIMEOUT_MS);
    const onParentAbort = () => ac.abort(ctx.abortSignal.reason);
    ctx.abortSignal.addEventListener("abort", onParentAbort, { once: true });

    try {
      let response: Response;
      try {
        response = await fetch(url, {
          signal: ac.signal,
          headers: { "User-Agent": USER_AGENT },
          redirect: "follow", // Bun/fetch follows up to 20 by default; we cap below if needed
        });
      } catch (err: unknown) {
        const msg = err instanceof Error ? err.message : String(err);
        return { content: `Fetch error: ${msg}`, isError: true };
      }

      const status = response.status;
      const contentType = response.headers.get("content-type") ?? "application/octet-stream";
      const ct = contentType.split(";")[0].trim().toLowerCase();

      // Read body up to maxBytes
      const arrayBuffer = await response.arrayBuffer();
      const bytes = new Uint8Array(arrayBuffer).slice(0, maxBytes);

      let body: string;

      if (ct === "text/html" || ct === "application/xhtml+xml") {
        const rawHtml = new TextDecoder().decode(bytes);
        body = htmlToText(rawHtml);
      } else if (ct === "application/json") {
        const rawText = new TextDecoder().decode(bytes);
        try {
          body = JSON.stringify(JSON.parse(rawText), null, 2);
        } catch {
          body = rawText;
        }
      } else if (ct.startsWith("text/")) {
        body = new TextDecoder().decode(bytes);
      } else {
        return {
          content: `binary content not supported, content-type: ${contentType}`,
          isError: true,
        };
      }

      const content = `URL: ${url}\nStatus: ${status}\nContent-Type: ${contentType}\n\n${body}`;
      return { content };
    } finally {
      clearTimeout(timeoutId);
      ctx.abortSignal.removeEventListener("abort", onParentAbort);
    }
  },
};
